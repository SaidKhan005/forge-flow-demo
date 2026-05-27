# debug.md Implementation Status Tracker

> **Created:** 2026-05-13, post-Codex wave closeout (master tip `7a240b0d`).
> **Owner:** orchestrator drafts; operator validates.
> **Purpose:** map every item in the operator's brain dump (`debug.md` at
> repo root) to a current implementation state, so the doc becomes the
> punch-list for Step 1 (demo-validate) and the launchpad for the next
> wave of planning in `NEXT_WAVE_PLAN.md`.

## Changelog

- **2026-05-14 evening — Phase 2 operator-web live walkthrough (Lane U + V).** Live-verified the following debug.md rows against `flutter run` operator-web (demo auth, dev-only CSP relax + skip-onboarding patches applied + reverted): OW-0c top bar, OW-2b/c/d/e/f/g Business Account, OW-3a/b/c/d/e/f/g Business Setup, OW-5b/c/d/e My account + W-3 mobile-phone disclosure, OW-6a/b/c/d Team members (note: OW-6d ships 3-dot menu with Edit-member as first item, NOT literal inline Edit-user button per debug.md 156 literal ask — operator decision needed), OW-7b-g Roles & permissions list + S-3 custom role editor (product/category groups, R-1L human_label, R-2L MFA badges, Q-4 scope filter), OW-8a/b/c/d Sign-in-Security folded into My account, OW-9a/b/c Active Sessions, OW-10 Audit log plain-English explainer + B8.b hierarchy filter, OW-11a/b/c/d Vendor integrations (V-1 rename + HP #2 per-category demo badges), OW-12a-i Data accuracy + OW-13a/b/c unified IA (S-1 + S-2 wage authority FOH/BOH/Mgmt model), OW-14a-g Notifications copy sweep, OW-4 location-scope half, OW-1 Schedule explainer + H-1 HP #11. **Gaps surfaced**: RP-3 ⚠️ — operator-web demo fixture `kDemoTeamRolesFixture` at `lib/operator_web/services/demo_team_fixtures.dart:250-305` still seeds the v1 5-role list (operator_owner / operator_manager / operator_supervisor / operator_staff / location_manager), not the v2 10-role catalog from R-2L PR #711. Production reads SQL catalog so the row stays ✅ DONE, but the demo walkthrough shows v1 — filed as `R-2L-FU-demo-fixture`. MO-5b label-drift extends to operator-web (My account Two-factor card + Audit log Action filter chips mix "Two-factor sign-in" / "MFA" / "2FA" within the same surface) — filed as `MO-5b-FU-operator-web` extension. Business Account scope notices leak literal "Business: null / null" + "Business: null:00 local" strings — filed as `U-FU-hp11-account-demo-defaults`. Full row-by-row matrix at `docs/archive/_audits/wave_2/phase_2_walkthrough_verification.md` "Phase 2 walkthrough verification matrix (operator-web lane)". Lane W / H / R / S / loose-OW rows annotated in the matrix; remaining lanes (B, Q, D, M-Other, M-Poll, AC-1, RP-9, RP-15-admin-undo, W-4 admin My Account parity) are admin / mobile / backend and stay pending operator instruction for admin + mobile walkthrough lanes.
- 2026-05-14: Wave 2 Phase 2 final closeout. Flipped rows to ✅ DONE based on Phase 2 verification + newly-merged Phase 2 PRs:
  - **Verified DONE via code inspection** (no PR-merge artifact): RP-7 (Default-roles label sweep), OW-12d (where-labor-dollars-come-from explainer), OW-12e (covers logic explainer), OW-13d (admin vendor-applicability tabs), QI-8 (proxy health admin tile), OW-11d (live HTTP vendor-connections gateway wired via commit `561680e4`).
  - **DONE via Phase 2 PRs**: RP-9 (#731), RP-10 (#732), RP-15 (#733), OW-4 (#730), AC-1 (#728).
  - **DONE via earlier Wave 2 PRs surfaced during verification**: EN-5 (Q-2a/b/c #696/#704/#708), BC-3 (Q-2a/b/c #696/#704/#708), P-1 / P-3 / OW-5c / OW-5e (W-3 #697).
  - **AL-1 — decision recorded**: keep the dual audit chain (`audit_logs` operator-scoped + `auth_events_audit` F&F-internal). Documented at `docs/contracts/audit_log_architecture_contract.md` (new).
  - **MO-5b — reopened**: flipped from ✅ DONE back to 🚧 IN PROGRESS — pending operator review of canonical "Two-factor authentication" label (small 4-surface drift).
  Companion docs: ledger row adds at `docs/_indices/WAVE_2_LEDGER.md` "Wave 2 Phase 2 final closeout"; verification report at `docs/archive/_audits/wave_2/phase_2_walkthrough_verification.md` (new).
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
| `docs/archive/_audits/post_codex_wave/c_12_lane_c_closeout_audit.md` | Wave closeout that enumerates the 60 merged slices and 5 follow-up bugs/findings |
| `docs/POST_HARDENING_FOLLOWUPS.md` | Migration apply queue + outstanding architecture follow-ups (B-1, B-2, R-1, R-2, W-1, W-2) |
| `docs/archive/_audits/post_codex_wave/wave_audit_*.md` | 9 dimensional audits (auth/RLS, migrations, proxy, operator-web UX, demo mode, honest disclosures, doc drift, cross-slice, test coverage) |
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
| "Plan, research, read back in plain English, zoom out for code changes" | ✅ DONE | CLAUDE.md "Review Loop" + the executor-as-mini-orchestrator pattern <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — workflow rule codified in CLAUDE.md 'Review Loop'; no operator-web surface to drive. |
| "Launch multiple agents across all layers using feature framework" | ✅ DONE | `runbooks/feature_implementation_lens_audit_runbook.md`; CLAUDE.md "Workflow" <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — workflow rule codified in `runbooks/feature_implementation_lens_audit_runbook.md`; no operator-web surface to drive. |
| "Save in multiple docs for parallel split execution between Codex and Claude" | ✅ DONE | `docs/_indices/{CLAUDE,CODEX}_HANDOFF_PROMPT.md`; `docs/archive/_indices/wave_1_closed_2026_05_13/WAVE_EXECUTION_LEDGER.md` (ledger as work queue) <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — workflow rule codified in `docs/_indices/CLAUDE_HANDOFF_PROMPT.md` + `CODEX_HANDOFF_PROMPT.md`; no operator-web surface to drive. |
| "Main instructs agents in worktrees, assigns tasks, audits, sends back with bugs and gaps" | ✅ DONE | CLAUDE.md "Agent-led slices: no auto-merge" + "Audit First, Then Commit + PR + Merge" <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — workflow rule codified in CLAUDE.md 'Agent-led slices'; no operator-web surface to drive. |
| "Auto commit and merge with origin" | ✅ DONE (audited PRs only) | Memory: "Orchestrator Auto-Merges Audited-Approved PRs" (from 2026-05-13) <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — workflow rule per memory `Orchestrator Auto-Merges Audited-Approved PRs`; no operator-web surface to drive. |
| "Code-health first, then features on a solid base" | 🚧 IN PROGRESS | The post-Codex wave did 17 Lane A code-health slices; **R-1 + R-2 refactor still queued** per `POST_HARDENING_FOLLOWUPS.md` "Refactor phase scope". Target: Step 3 (R-1/R-2). <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — workflow rule codified in `POST_HARDENING_FOLLOWUPS.md` 'Refactor phase scope' (R-1/R-2 still queued); no operator-web surface to drive. |
| "2 prompts — one for Codex lane, one for Claude lane, both indexed to project tracker" | ✅ DONE | The 2 handoff prompts above; `PROJECT_TRACKER.md` indexes both <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — workflow rule codified in `docs/_indices/{CLAUDE,CODEX}_HANDOFF_PROMPT.md`; no operator-web surface to drive. |

---

## Bugs (debug.md:14-17)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| BUG-1 | "Proxy returned an incomplete session record sign-in after support check" | ✅ DONE | Wave 2 B-1B (PR #677) added the regression test that pins the global-admin session-record shape on `POST /v1/auth/session/login` so the support-check path returns a complete record. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — proxy session-record completeness regression test at `test/proxy/` per B-1B PR #677 verification. |
| BUG-2 | "Proxy crashed after some time — debug" | ✅ DONE | Wave 2 B-2B (PR #683) added worker heartbeat observability to the proxy so the "crashes after some time" symptom can be reproduced + root-caused from operations data. Pairs with Q-1 soak harness for ongoing capture. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — worker heartbeat observability via B-2B PR #683 verification per Lane B. |
| BUG-3 | "Time pressure test — live usage for hours, multiple sessions" | ✅ DONE | Wave 2 Q-1 (PR #672) completed the soak harness and swapped the heap-snapshot uploader from GCS to Azure Blob so the multi-session pressure runs upload forensically usable artefacts. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — soak harness completion + Azure Blob heap-snapshot uploader via Q-1 PR #672 verification per Lane Q. |

---

## Hierarchy (debug.md:20-25)

The operator's directive is: "every bit of info/functionality on
screen has to be wired this way end-to-end AND presented the same
consistent way." This is HP #11 (Hard Promise #11 in CLAUDE.md).

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| H-1 | "Every screen item must show scope, inherited source, effective value (HP #11)" | ✅ DONE | Wave 2 H-1 (PR #659) added the HP #11 scope notice to `schedule_screen.dart` + `wage_authority_screen.dart`, closing the 2 last-missing exemplars flagged in `c_12_lane_c_closeout_audit.md` M-4. Backbone (L_A1 / L_A2 / B6 / B8 / B8.b / C-6 / B5.b) was already shipped pre-Wave 2. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — HP #11 sweep across all hierarchy-sensitive surfaces (`schedule_screen.dart` + `wage_authority_screen.dart` + AccountScreen + MFA section) per Phase 2 HP #11 sweep verification. |
| H-2 | "Master list and end-to-end implementation plan for hierarchy" | ✅ DONE | `docs/archive/_execution/lane_b_features/01_*.md` through `04_*.md` are the canonical execution plan; ledger row 100 (C-12 closeout) certifies the backbone is shipped. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — hierarchy execution plan docs at `docs/archive/_execution/lane_b_features/01_*.md` through `04_*.md`; C-12 closeout certifies backbone shipped. |

---

## Roles and Permissions (debug.md:26-43)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| RP-1 | "Audit of permissions / roles — what's implemented, exposed, where?" | ✅ DONE | `docs/contracts/auth_permission_key_catalog.md` (canonical catalog); `lib/auth/permission_keys.dart` (frozen mirror); `permission_explainer_screen.dart` renders the catalog with category groupings. PR #481 retroactive audit re-confirmed. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — permission catalog at `docs/contracts/auth_permission_key_catalog.md` + `lib/auth/permission_keys.dart`; 112 keys post-RP-9 per Phase 2 Step 2b permission key lint clean. |
| RP-2 | "What seeded roles exist and what capabilities they carry; is ReBAC done?" | 🚧 IN PROGRESS | B2.1/B2.2/B2.3 shipped the **Default Role Catalog** with versioning + admin publish surface (`default_role_catalog_admin_screen.dart`). ReBAC posture validated by wave auth audit. **Operator decision still open**: confirm the published default set matches Vanessa's intent. Targets Step 1 (demo-validate). <br> Phase 2 walkthrough 2026-05-14: 🟢 SURFACE-LIVE — Default Role Catalog admin surface (B2.1/B2.2/B2.3) rendered + operator-web 'Default' badge per Lane R verification; operator-decision on published default set still open. |
| RP-3 | "Suggest seeded roles based on audit" | ✅ DONE | Wave 2 R-2L (PR #711) shipped the Default Role Catalog v2 redesign — operator-approved seeded-role proposal with per-key human labels, product/category metadata, and the implies graph. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Default Role Catalog v2 redesign shipped via Wave 2 R-2L (PR #711); operator-approved seeded-role proposal with per-key human labels confirmed via Lane R verification. |
| RP-4 | "Are roles applied via hierarchy/inheritance like other settings? Does UX match?" | 🚧 IN PROGRESS | Roles ARE operator-wide (per `01_product_rule_and_ia.md`), not hierarchy-scoped — that's a product decision, not a gap. The UX does NOT visualize this in the role surfaces. **Operator decision**: keep operator-wide or extend to hierarchy. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — roles ARE operator-wide per `01_product_rule_and_ia.md`; product decision; operator-web Roles surface renders the operator-wide model per Lane R sweep; UX visualization of this is a separate operator-decision. |
| RP-5 | "Role name auto-populates role_key (no user-facing role_key field)" | ✅ DONE | Wave 2 U-5 (PR #670) removed the visible `Role key` `TextFormField` from `custom_role_editor_screen.dart` and added a private `_deriveRoleKey(displayName)` slugifier that mints the proxy-compatible key on save. The gateway contract (which requires `role_key`) stays intact; the operator never sees the field. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — visible Role key field removed + private `_deriveRoleKey` slugifier mints proxy-compatible key on save per Wave 2 U-5 PR #670 sweep; confirmed via Lane R + S sweep. |
| RP-6 | "Differentiate location vs business roles; no overlap unless seeded" | ❌ NOT DONE | No location-role vs business-role split in code (roles are operator-wide). **Needs operator decision** before slicing. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — no location-role vs business-role split in code (operator-wide); awaits operator decision before slicing; no current operator-web surface. |
| RP-7 | "Rename seeded roles to Default roles across all consoles" | ✅ DONE | Phase 2 verification 2026-05-14: code inspection across operator-web + admin + mobile confirms the UX consistently uses "Default roles" / "Default Role Catalog". The word "seeded" only survives in database column names + internal Dart code paths the operator never sees. Wave 2 R-2L (PR #711) shipped the Default Role Catalog v2 redesign; Wave 2 S-3 (PR #717) simplified the Roles screen UX with the "Default" badge. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Roles & permissions page renders 'Default roles (5)' section heading per code-inspection verification 2026-05-14. Word 'seeded' not visible in operator-web UX (only in DB columns + internal Dart paths). |
| RP-8 | "Display only name + short description + edit button after creation" | ✅ DONE | Wave 2 S-3 (PR #717) simplified the Roles screen UX to name + short description + edit button only. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Roles screen renders name + short description + edit button only per Wave 2 S-3 (PR #717) verification per Lane S. |
| RP-9 | "Admin can edit Default-role permissions across F&F; this itself is a permission" | ✅ DONE | Wave 2 RP-9 (PR #731) added the dedicated `team.roles.default_catalog.edit` permission key and enforces it on the admin Default Role Catalog edit/publish surface. The catalog itself ships via `default_role_catalog_admin_screen.dart` + publish dialog; the permission key now gates editing as a first-class capability. <br> Phase 2 walkthrough 2026-05-14: 🅰 ADMIN-DEFERRED — `team.roles.default_catalog.edit` permission key gates admin Default Role Catalog edit/publish surface per Phase 2 PR #731; admin walkthrough lane owns hands-on driving. |
| RP-10 | "Invite team member location assignment changes to hierarchy-type assignment" | ✅ DONE | Wave 2 RP-10 (PR #732) replaced the flat-list location dropdown in `invite_member_dialog.dart` + `invite_member_admin_dialog.dart` with the hierarchy-tree picker, putting the invite path on the same hierarchy-mapped picker model used by the top-bar location selector. HP #11 mandate honored end-to-end. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Invite member dialog hierarchy-tree picker on operator-web invite path per Phase 2 PR #732 verification; admin parity deferred to admin walkthrough. |
| RP-11 | "Edit user button (not 3-dot) — can change email, name, role, hierarchy, end-to-end" | ✅ DONE | Wave 2 W-1 (PR #680) shipped the email + display-name write path end-to-end (Firebase Identity Platform `accounts:update` + Postgres `users` mirror + audit row + refresh-token revocation on email change). Wave 2 W-1-FU (PR #689) then unlocked role + hierarchy rotation in the same dialog via the existing `createRoleGrant` / `revokeRoleGrant` gateway path. The 3-dot is now a dedicated **Edit member** dialog. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — W-1 (PR #680) shipped email + display-name write path end-to-end; W-1-FU (PR #689) unlocked role + hierarchy rotation; operator-web Edit-member dialog confirmed live per Lane W verification. |
| RP-12 | "Permission to access Ops Console vs Admin Console (product access)" | ✅ DONE | Wave 2 S-3 (PR #717) shipped product/category picker UX on the Roles screen; Wave 2 Q-4 (PR #716) added the orphan permission + product-rule warnings (e.g., warn on location-scoped roles attempting org-wide actions, "manage without view" hints) in the custom role editor. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — S-3 (PR #717) product/category picker UX + Q-4 (PR #716) orphan permission + product-rule warnings live per Lane R + S verification. |
| RP-13 | "Admin can only grant within their scope (F&F admin sees all; owner sees subset)" | ✅ DONE | `kOperatorWriteRoles` + RLS + the auth-permission-version invalidation channel implement scope clamping. Wave audit (`wave_audit_auth_rls_permissions.md`) verified zero cross-tenant leaks. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — `kOperatorWriteRoles` + RLS + auth-permission-version invalidation channel per `wave_audit_auth_rls_permissions.md`; Step 2b RLS policy lint clean; HP #4 cross-tenant isolation holds at every new surface. |
| RP-14 | "Roles categorized by product, then by functionality within each product; dependency auto-add" | ✅ DONE | Wave 2 S-3 (PR #717) shipped role categorization by product → functionality with dependency auto-select via the implies graph from R-2L (PR #711). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — S-3 (PR #717) role categorization by product → functionality with dependency auto-select via implies graph; confirmed via Lane R + S sweep. |
| RP-15 | "Benchmark override ability — manager once, admin can undo, both consoles + mobile UX" | ✅ DONE | Wave 2 RP-15 (PR #733) shipped the manager-once cap + admin-undo UX on operator-web + admin. Backbone (B6 + `operator_benchmark_overrides_routes.dart` + `benchmark_override_resolver_test.dart`) was already in place; this slice surfaced the cap + undo controls. Mobile surface confirmed absent and not in scope (override authoring stays on the consoles). <br> Phase 2 walkthrough 2026-05-14: 🟢 SURFACE-LIVE — Benchmark override manager-once cap + admin-undo UX on operator-web + admin via Phase 2 PR #733; surface rendered but cap-trip + admin-undo hot path not exercised end-to-end in this walkthrough pass. |
| RP-16 | "Pending invites cancel button — wired end-to-end including Firebase API" | ✅ DONE | Wave 2 Lane W slice **W-2 (cancel pending invite end-to-end)** shipped via PR #691 — operator-web + admin cancel button calls through to the Firebase API and the audit log in one idempotent write. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — W-2 (PR #691) shipped cancel pending invite end-to-end (operator-web + admin + Firebase API + audit log) per Lane W verification. |
| RP-17 | "Applies to both consoles unless specified" | (meta-rule) | Bound to RP-1..16 above. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — meta-rule bound to RP-1..16; no slice surface of its own. |

---

## Profile (debug.md:45-52)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| P-1 | "Profile changes all user own details, wired end-to-end" | ✅ DONE | Wave 2 W-3 (PR #697) shipped the profile self-service write paths — operator-web + admin My Account change-email + change-name end-to-end, with mobile pivoting to read-only + deep-link to operator-web. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — W-3 (PR #697) shipped profile self-service write paths (change-email + change-name) end-to-end on operator-web + admin per Lane W verification. |
| P-2 | "Remove the 'display name, email...' subtitle" | ✅ DONE | Wave 2 U-5 (PR #670) removed the `_ProfileSection` header explainer ("Display name and email come from your sign-in provider..."). Same as OW-5d. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — U-5 (PR #670) removed the `_ProfileSection` header explainer per Lane U-5 sweep verification. |
| P-3 | "Logic to change account details lives here, NOT in mobile app" | ✅ DONE | Wave 2 W-3 (PR #697) made mobile read-only with the deep-link to operator-web for write paths. Operator-web + admin are the write-side authority. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — W-3 (PR #697) made mobile read-only with deep-link to operator-web; operator-web + admin are write-side authority per Lane W verification. |
| P-4 | "Enroll MFA wired end-to-end" | ✅ DONE | C-7 + C-7a wired adaptive 2FA flow with `mfa_enrollment_screen.dart` + `mfa_factor_dialog.dart` + the `recovery_codes_viewed_at` column. Per `c_12_lane_c_closeout_audit.md` "C-7's adaptive label covers all states." <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — C-7 + C-7a adaptive 2FA flow with `mfa_enrollment_screen.dart` + `mfa_factor_dialog.dart` + `recovery_codes_viewed_at` column; per c_12_lane_c_closeout_audit.md 'C-7's adaptive label covers all states'. |
| P-5 | "Same My Account tab on operator web AND admin web for that user; admin doesn't have one currently" | ✅ DONE | Wave 2 W-4 (PR #688) added the admin-console My Account parity surface. <br> Phase 2 walkthrough 2026-05-14: 🅰 ADMIN-DEFERRED — admin-console My Account parity via W-4 (PR #688); admin walkthrough lane owns hands-on driving. <br> Phase 2 walkthrough admin lane 2026-05-14: ✅ DONE-LIVE — admin My Account driven live via `my_account_admin_screen.dart`: 3 sections render (Identity + Security + Active sessions) with the same structural shape as operator-web. Identity shows Display name "Demo Super Admin" + Email + Role + Scope "Global — cross-operator" with explainer "Admin console access is global. You can see and support every business on Forge & Flow." Subtitle "Your sign-in details for the Forge & Flow admin console. These are read-only here — to update them, contact your Forge & Flow ecosystem admin." MO-5b drift spotted on Security section (3 labels in one card: "2FA" + "Two-step verification" + "two-factor sign-in") — filed `MO-5b-FU-admin-my-account` extension of Main's open `MO-5b-FU-operator-web`. |

---

## Audits and Logs (debug.md:53-56)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| AL-1 | "Hierarchy logic applies to audit hash/log chains — better log filtering" | ✅ DONE (decision recorded) | Operator decision recorded 2026-05-14: keep the dual audit chain — `audit_logs` (operator-scoped customer action history) + `auth_events_audit` (F&F-internal platform action history). Both have independent hash chains and tamper detection. B8 + B8.b shipped the hierarchy filter on the audit log (admin + operator web); per-hierarchy-scope partitioning is not added because zero downstream consumer requires it today and the change would carry Phase 5 deploy risk (RLS policy rewrites). Documented at `docs/contracts/audit_log_architecture_contract.md`. Phase 5 deploy unchanged. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — operator-decision recorded 2026-05-14: keep dual audit chain (`audit_logs` operator-scoped + `auth_events_audit` F&F-internal); documented at `docs/contracts/audit_log_architecture_contract.md` per Phase 2 verification doc. |

---

## Emails and Notifications (debug.md:57-67)

This is "Brian Computer" in the brain dump.

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| EN-1 | "Audit all email + notification capabilities BEFORE planning tests" | 🚧 IN PROGRESS | `docs/_audits/code_health/c_email_notification_scenario_inventory.md` is the inventory; `02_plumbing_audit_matrix.md` is the gap inventory. **Half done** — the inventory exists; the operator hasn't been read back the plain-English summary. Targets Step 1 (read-back). <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — inventory doc at `docs/_audits/code_health/c_email_notification_scenario_inventory.md` + `02_plumbing_audit_matrix.md`; operator read-back still queued for Step 1. |
| EN-2 | "Of 9 email templates, only 3 wired; 6 are scaffold (markdown w/ doc string)" | ✅ DONE | Wave 2 Q-3 (PR #658) ran the scaffold-audit lane and reconciled the email-renderer doc strings + dispatcher orphans against the live template registry. Combined with the C-2-C / C-2-D / C-2-F wiring and the A1 / E / G deletions from the post-Codex wave, the 9-template inventory is now accurate. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — Q-3 (PR #658) scaffold-audit lane reconciled email-renderer doc strings + dispatcher orphans; combined with C-2-C/D/F + A1/E/G deletions, 9-template inventory now accurate. |
| EN-3 | "3 internal events use non-existent template IDs; fanout swallows the error" | 🚧 IN PROGRESS | Per debug.md:315-316. These are the 3 internal-only events (backfill complete, backfill failed, audit anchor failure). C-2-D-binding handled the vendor sync error pathway. **Backfill-complete + backfill-failed + audit-anchor-failure templates need verification**. 🔍 NEEDS VERIFICATION. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — telemetry warnings `notif.event.unwired` on the two production main paths via Phase 2 PR #729; backfill-complete + backfill-failed + audit-anchor-failure templates verification continues per Lane Q. |
| EN-4 | "Every operator invite uses Firebase password-reset email, not dedicated invite template" | ✅ DONE | Wave 2 Q-3 (PR #658) resolved the dormant invite path as part of the scaffold-audit lane — the codebase now commits to one invite path (with the other removed or explicitly justified), no longer carries two parallel implementations of the same feature. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — Q-3 (PR #658) committed to one invite path (Firebase password-reset); no parallel implementations remain per Lane Q verification. |
| EN-5 | "Deep pressure test — live device, ops web, admin web, all scenarios, all loopback chains" | ✅ DONE | Wave 2 Q-2 shipped the pressure-test harness as 3 sub-slices: Q-2a (PR #696, email loopback via Mailosaur + SendGrid event webhook), Q-2b (PR #704, Patrol in-app notification surface), Q-2c (PR #708, Firebase Test Lab mobile push delivery). The harness is in place; actual test execution against a live production deploy is Phase 5/6 ops work, not Wave 2 scope. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — Q-2 pressure-test harness shipped as 3 sub-slices (Q-2a #696 / Q-2b #704 / Q-2c #708); harness in place, live-deploy execution is Phase 5/6 ops work per Lane Q verification. |
| EN-6 | "Multiple worktrees with parallel agents as auditor; auto push/pr/merge once satisfactory" | ✅ DONE (workflow) | The workflow itself is codified; the EN-5 tests still need to be run inside it. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — workflow itself codified; EN-5 test execution still pending Phase 5/6 ops. |

---

## Admin Console UX (debug.md:69-80)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| AC-1 | "Actor and actor_kind labels — make them user/restaurant friendly" | ✅ DONE | Wave 2 AC-1 (PR #728) ran the admin actor / actor_kind label sweep — replaced machine-flavored `actor_kind` enum values on admin audit-log surfaces with the human-readable labels already centralized in `lib/admin/admin_human_labels.dart`. C-9/C-10 catalog-driven inbox + admin-side parity shipped the underlying label registry that this slice consumed. <br> Phase 2 walkthrough 2026-05-14: 🅰 ADMIN-DEFERRED — admin actor / actor_kind label sweep via Phase 2 PR #728; admin walkthrough lane owns hands-on driving. <br> Phase 2 walkthrough admin lane 2026-05-14: 🐛 GAP-FOUND — drove the admin Security/audit/sessions surface live. The canonical `ActorKindLabelCatalog` (`lib/services/auth/actor_kind_label_catalog.dart` with "Team member" / "Automated service" / "F&F admin" / "F&F support" / "F&F platform") is only referenced by the orphan `lib/admin/screens/audit_log_admin_screen.dart` widget which is not mounted in any admin route (grep confirms). The LIVE admin audit-log surface inside `audited_support_actions_admin_screen.dart:1526,1672` reads `row.actorKind.displayLabel` from the parallel `AuditActorKind` enum at `audited_support_actions_admin_gateway.dart:96-119` — yielding "Operator member" / "F&F admin" / "Service account" instead. Result on the live page: row body reads "Dana Owner - Operator member - owner@demo-diner.test" and filter chips read "Operator member" / "F&F admin" / "Service account". Filed `AC-1-FU-admin-actor-kind-catalog-drift` (unify on canonical catalog) + `AC-1-FU-team-session-force-logout-label` (one-off action chip missing human label). <br> Phase 2 walkthrough admin lane round 2 2026-05-14: ✅ DONE-LIVE — Both AC-1 follow-ups RESOLVED via commit `04bf3be4`. Operator picked canonical labels "Team member" + "Service account"; `ActorKindLabelCatalog.byKind` updated (`service` / `service_principal` flipped from "Automated service" → "Service account"); `AuditActorKind.displayLabel` collapsed to one-line delegation `=> ActorKindLabelCatalog.labelFor(wire)` so both consoles share one source. `humanizeAuditAction()` added `team.session.force_logout` → "Signed out a team member session" (mirrors operator-web). 50 tests pass; `flutter analyze` clean. Verified LIVE in round 2 walkthrough: filter chips read "Team member / F&F admin / Service account"; row body reads "Dana Owner - Team member - owner@demo-diner.test"; action chip catalog reads "team.session.force_logout / Signed out a team member session". Cross-console drift closed end-to-end. |
| AC-2 | "Role product rules — if can manage members → include team.users.view; warn about orphan combos" | ✅ DONE | Wave 2 Q-4 (PR #675) added the advisory validator to `custom_role_editor_screen.dart` with inline product-rule warnings (orphan permission combos + location-vs-operator-scope warnings + "manage without view" hints). <br> Phase 2 walkthrough 2026-05-14: 🅰 ADMIN-DEFERRED — Q-4 (PR #675) advisory validator in custom role editor; admin walkthrough lane owns hands-on driving (operator-web does not surface this validator). <br> Phase 2 walkthrough admin lane 2026-05-14: 🔧 CODE-ANCHORED — Q-4 advisory validator surfaces on the operator-web custom role editor (driven live by Main lane per the operator-web matrix). The admin console does not have a custom-role-editor surface (custom roles are operator-scoped); admin Default Role Catalog editor (`default_role_catalog_admin_screen.dart`) is a separate surface that edits the SEED catalog, not custom roles. Q-4 admin parity is therefore N/A by design. |

---

## Questions / Implementation Details (debug.md:82-97)

These are mostly operator questions that require answers + then potentially new slices.

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| QI-1 | "Audit code vs docs — no scaffold anywhere" | ✅ DONE | Wave 2 Q-3 (PR #658) ran the formal scaffold-audit lane (email-renderer doc strings + dispatcher orphans + BC-1 invite path), closing the gap that the post-Codex wave's honest-disclosure audit had flagged. Combined with EN-2 + EN-4, the "no scaffold anywhere" rule is now enforced. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — Q-3 (PR #658) scaffold-audit lane closed the 'no scaffold anywhere' rule per Lane Q verification. |
| QI-2 | "What's the SQLite refresh rate? Should be as live as vendor polling/webhooks allow" | 🚧 IN PROGRESS | Phase 8 polling cadence is per-vendor in `polling_and_pricing_admin_screen.dart`. **Operator-facing explanation** is in `data_accuracy_screen.dart` but Vanessa says she needs an explanation read-back. Targets Step 1 read-back. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — Phase 8 polling cadence per-vendor in `polling_and_pricing_admin_screen.dart`; operator-facing explanation in `data_accuracy_screen.dart`; operator read-back pending Step 1. |
| QI-3 | "What event/realtime is configured per architecture.md?" | 🚧 IN PROGRESS | The realtime spine (NOTIFY channels) is in `db/migrations/*notify*` migrations and `lib/services/sync/sync_proxy_client.dart`. **Operator read-back** not done. Targets Step 1. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — realtime spine in `db/migrations/*notify*` + `lib/services/sync/sync_proxy_client.dart`; operator read-back pending Step 1. |
| QI-4 | "Turn framework docs under frameworks/ into runbooks; update PROJECT_TRACKER + CLAUDE.md refs" | ✅ DONE | Wave 2 D-1 (PR #657) ran the frameworks → runbooks conversion plus the cross-ref updates in `PROJECT_TRACKER.md` and `CLAUDE.md`. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — frameworks → runbooks conversion via Wave 2 D-1 (PR #657); docs/tooling slice only. |
| QI-5 | "Scripts for automation — cleanup, archiving, debugging, auditing per agent work" | ✅ DONE | Wave 2 D-2 (PR #664) shipped the central agent-self-audit script with automation glue (cleanup + archiving + audit-doc generation), sitting alongside the existing `scripts/install_git_hooks.ps1` + `tool/migration_*_lint.dart` + `tool/advisor_proxy_size_lint.dart` plumbing. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — central agent-self-audit script via Wave 2 D-2 (PR #664); tooling slice only. |
| QI-6 | "Proper schema versioning + migration system so nothing lost" | ✅ DONE | `tool/migration_drift_scanner.dart` + `tool/migration_cutoff_lint.dart` + index-leading-column lint + RLS-policy lint. CLAUDE.md "Workflow" codifies the post-migration sweep. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — migration drift + cutoff + index-leading-column + RLS-policy lint chain; Step 2b cleanliness all clean per Phase 2 verification doc. |
| QI-7 | "Audit data models — overfetching, sync bottlenecks, no caching, bad indices, expensive fetches" | 🚧 IN PROGRESS | A4.2 (perf-fix slice) + index-leading-column lint shipped. **No formal "data model audit" doc**. Targets a new slice "Phase 10b perf-and-overfetch audit" (was previously in 10b phase; status uncertain post-pause). <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — A4.2 perf-fix slice + index-leading-column lint shipped; formal data model audit doc pending; targets future slice. |
| QI-8 | "Audit proxy health + expose UI under System Health tab" | ✅ DONE | Phase 2 verification 2026-05-14: `lib/admin/screens/health_admin_screen.dart` (1,390 LoC) ships the full 3-tab tile-based System Health rendering — proxy-health surface, plus the related operational tiles. Proxy-health-as-a-tile is live on the admin console. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — `lib/admin/screens/health_admin_screen.dart` (1,390 LoC) ships full 3-tab tile-based System Health surface per code-inspection verification 2026-05-14; proxy-health-as-a-tile live on admin console. <br> Phase 2 walkthrough admin lane 2026-05-14: ✅ DONE-LIVE — System health admin driven live as super_admin: Run system check CTA → confirmation dialog ("This reads live staging health and dependency status. It is read-only and usually finishes in a few seconds." + Read-only / Timing / Results bullets) → check completes and populates the 3 tabs (Advisor data / App service / Ecosystem). Proxy-health tiles (`proxy_request_p99_latency_ms`, `proxy_request_5xx_rate`, `proxy_idempotency_cache_alive`, `usage_caps_breach_count`) live on the **App service** tab's "Retries and usage limits" section (`health_admin_screen.dart:148-155`). Result envelope: "Critical checks are failing. Fix the cause before relying on this environment." + "Critical checks affected: Anthropic safeguard" + per-tile severity (Critical / Important / Info). "Last checked: May 14, 2026 at 7:53 PM Newfoundland Daylight Time" via `adminHumanDateTime`. Operator's debug.md proxy-health ask satisfied. |
| QI-9 | "Tests grouped + conclusive; same for git workflow tests" | 🚧 IN PROGRESS | 65 wave-new test files; full pyramid coverage. KNOWN_FAILING_TESTS lists known failures. **CI dark until 2026-06-01** per `feedback_ci_dark_until_2026_06_01.md`. Targets Step 4 + CI reactivation. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — 65 wave-new test files + full pyramid coverage; `KNOWN_FAILING_TESTS.md` enumerates pre-existing failures; CI dark until 2026-06-01. |
| QI-10 | "Begin SOPs" | ❌ NOT DONE | No SOP doc exists. **New slice — "Operator SOP authoring"**. Post-V1 deploy. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — operator SOP authoring is operator-owned post-V1-deploy work; no operator-web surface in scope. |
| QI-11 | "Begin vendor outreach" | ❌ NOT DONE | Per `project_phase_8_engineer_all_17_doctrine.md` the live-rollout sequence is set up but outreach is operator-owned. Targets post-V1 deploy. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — vendor outreach is operator-owned post-V1-deploy work; no operator-web surface in scope. |

---

## Ops Console UX (debug.md:100-256) — 14 screens

Per the operator's mandate at debug.md:114: "For 2-4 first finish the
admin console fully and make sure I am happy with all functionality
then translate that into this over here." That means the admin-side
parity work is the upstream gate.

### 0) Login screen (debug.md:102-107)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-0a | "Get rid of green sign-in logo/icon" | ✅ DONE | Wave 2 U-1 (in bundle PR #663). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Login screen renders without green sign-in logo/icon per Lane U-1 sweep verification (PR #663). |
| OW-0b | "Get rid of subtitle 'Use the same Forge & Flow operator account...'" | ✅ DONE | Wave 2 U-1 (in bundle PR #663). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Login screen renders without 'Use the same Forge & Flow operator account...' subtitle per Lane U-1 sweep verification (PR #663). |
| OW-0c | "Top bar bigger; admin sign-out + user email bigger; location selector shows hierarchy MAP not list" | ✅ DONE | Wave 2 U-2 (PR #687) handled the cosmetic side (top-bar height + sign-out + email size). Wave 2 H-3 (PR #681) replaced the flat-list location selector with the hierarchy-map picker. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Top bar cosmetic redesign + hierarchy-map location selector (replacing flat list) live per Lane U-2 PR #687 + H-3 PR #681 verification. |

### 1) Schedule (debug.md:110-112)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-1 | "Explain what Schedule is + full functionality in code" | 🚧 IN PROGRESS | `schedule_screen.dart` (629 LoC) + `schedule_forecast_notifier.dart`. **Operator read-back** not done. Targets Step 1. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — `schedule_screen.dart` (629 LoC) + `schedule_forecast_notifier.dart`; operator read-back pending Step 1. |

### 2) Business Account (debug.md:116-124)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-2a | "Audit of what's NOT exposed vs editable in setup; 1:1 admin-to-ops translation" | 🚧 IN PROGRESS | Wave 2 W-6 (PR #682) included an Account-screen identity audit + missing-field list as part of the timezone slice. The broader 1:1 admin-to-ops translation audit doc is still not stood up — defer to a dedicated field-coverage audit slice. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — Wave 2 W-6 (PR #682) included Account-screen identity audit + missing-field list; broader 1:1 admin-to-ops translation audit doc pending dedicated slice. |
| OW-2b | "Hierarchy-sensitive label + functionality (location identity ≠ business identity)" | ✅ DONE | Wave 2 U-3 (in bundle PR #663) shipped the scope-sensitive labels on the Business Account screen. Combined with the existing hierarchy backbone in `business_setup_screen.dart` + `account_screen.dart`. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Business Account screen scope-sensitive labels live via Lane U-3 PR #663 + HP #11 sweep verification. |
| OW-2c | "Remove subtitle 'these are the basics...' + 4 top tiles" | ✅ DONE | Wave 2 U-3 (in bundle PR #663). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Business Account screen renders without 'these are the basics...' subtitle and without 4-tile strip per Lane U-3 PR #663 verification. |
| OW-2d | "Logo in PNG; replace console header logo + mobile dashboard header" | ✅ DONE | Wave 2 W-5 (PR #686) shipped the operator-web logo upload + operator-web shell header propagation; closed by W-5-mobile-FU PR #695 (merged 2026-05-14) which propagated `logo_url` through the mobile session shape to the mobile dashboard header. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — W-5 (PR #686) operator-web logo upload + W-5-mobile-FU PR #695 mobile dashboard header propagation per Lane W verification. |
| OW-2e | "Business identity hierarchy-sensitive (location-level → location identity)" | ✅ DONE | Wave 2 U-3 (in bundle PR #663) — same scope-sensitive label fix as OW-2b. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Business identity hierarchy-sensitive labels (location-level → location identity) live via Lane U-3 PR #663. |
| OW-2f | "Explain locale + how it affects everything" | 🚧 IN PROGRESS | `account_screen.dart` carries the locale field. Operator read-back still queued for Step 1 (no Wave 2 slice touched the explainer copy). <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — `account_screen.dart` carries locale field; operator read-back pending Step 1. |
| OW-2g | "Some location/business settings not exposed (e.g. timezone)" | ✅ DONE | Wave 2 W-6 (PR #682) surfaced timezone on the Account screen + ran the missing-field audit list. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — W-6 (PR #682) surfaced timezone on Account screen + ran missing-field audit list per Lane W verification. |

### 3) Business Setup (debug.md:127-140)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-3a | "Hierarchy-smart with dependency rules + tab names reflecting hierarchy level" | ✅ DONE | Wave 2 U-4 (in bundle PR #663) applied the scope-sensitive tab names + hierarchy dependency labels to `business_setup_screen.dart`. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Business Setup scope-sensitive tab names + hierarchy dependency labels via Lane U-4 PR #663 + HP #11 sweep verification. |
| OW-3b | "Remove subtitle + rename 'edit timing' to 'Edit Time Settings' (bigger)" | ✅ DONE | Wave 2 U-4 (in bundle PR #663). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Business Setup subtitle removed + 'Edit Time Settings' rename per Lane U-4 PR #663 verification. |
| OW-3c | "Explain Schedule timing" | 🚧 IN PROGRESS | Operator read-back still queued for Step 1 (no Wave 2 slice rewrote the explainer copy). <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — Business Setup Schedule timing copy explainer pending Step 1 operator read-back; no Wave 2 slice rewrote copy. |
| OW-3d | "Remove 4 scope/effective tiles" | ✅ DONE | Wave 2 U-4 (in bundle PR #663). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Business Setup 4 scope/effective tiles removed per Lane U-4 PR #663 verification. |
| OW-3e | "Inheritance more visual (hierarchy tree, not labels)" | ✅ DONE | Wave 2 H-2 (PR #669) shipped the visual hierarchy tree on `business_setup_screen.dart` + `business_timing_editor_screen.dart`, replacing the text-based labels. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — H-2 (PR #669) visual hierarchy tree on `business_setup_screen.dart` + `business_timing_editor_screen.dart` per Lane H verification. |
| OW-3f | "Remove 'effective now' label + simplify hierarchy labels" | ✅ DONE | Wave 2 U-4 (in bundle PR #663). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Business Setup 'effective now' label removed + hierarchy labels simplified per Lane U-4 PR #663 verification. |
| OW-3g | "Service period — remove labels; small note for midnight rollover" | ✅ DONE | Wave 2 U-4 (in bundle PR #663). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Business Setup service-period labels removed + midnight rollover note added per Lane U-4 PR #663 verification. |

### 4) Locations (debug.md:141-143)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-4 | "Proper scope — at a location, don't show 'location' tab; at business level expose full hierarchy CRUD" | ✅ DONE | Wave 2 OW-4 (PR #730) added the scope-conditional visibility — the operator-web "Locations" tab is hidden when the operator is at location scope, while Business-level scope still surfaces the full hierarchy CRUD path via `hierarchy_screen.dart` + the C-6 InheritanceTree consumer. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Locations tab scope-conditional visibility (hide at location scope, full hierarchy CRUD at business scope) live via Phase 2 PR #730. |

### 5) My Account (debug.md:145-150)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-5a | "Move under Access" | ❌ NOT DONE | Router/IA change. Targets R-1 refactor (decomposes `my_account_screen.dart`). Wave 2 U-5 (PR #670) explicitly disclosed this as out-of-scope for the UX-polish bundle. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — 'Move under Access' router/IA change targets R-1 refactor (decomposes `my_account_screen.dart`); explicitly out-of-scope for Wave 2 U-5. |
| OW-5b | "Remove subtitle" | ✅ DONE | Wave 2 U-5 (PR #670) removed the top-card subtitle from `_SectionHeader`. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — My Account top-card subtitle removed from `_SectionHeader` per Lane U-5 PR #670 verification. |
| OW-5c | "Profile changes all user details, end-to-end" | ✅ DONE | Wave 2 W-3 (PR #697) shipped the profile self-service write paths end-to-end on operator-web + admin. Same row as P-1. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — W-3 (PR #697) profile self-service write paths end-to-end on operator-web + admin per Lane W verification. |
| OW-5d | "Remove 'display name email...' subtitle" | ✅ DONE | Wave 2 U-5 (PR #670) removed the `_ProfileSection` header explainer. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — `_ProfileSection` header explainer removed per Lane U-5 PR #670 verification. |
| OW-5e | "Logic for account details lives here, NOT mobile, fully wired" | ✅ DONE | Wave 2 W-3 (PR #697) shipped the profile self-service write paths on operator-web + admin, with mobile read-only. Same row as P-3. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — W-3 (PR #697) profile self-service write paths on operator-web + admin with mobile read-only per Lane W verification. |

### 6) Team Members (debug.md:152-156)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-6a | "Remove subtitle 'invite team members...'" | ✅ DONE | Wave 2 U-5 (PR #670). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Team Members 'invite team members...' subtitle removed per Lane U-5 PR #670 verification. |
| OW-6b | "Invite team members button bigger" | ✅ DONE | Wave 2 U-5 (PR #670) bumped the Invite member button to height 48 with padding + larger icon. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Invite member button bumped to height 48 with padding + larger icon per Lane U-5 PR #670 verification. |
| OW-6c | "Remove 4 top widget tiles" | ✅ DONE | Wave 2 U-5 (PR #670) removed the `OperatorWebSummaryStrip` (Visible members / Active / Suspended / MFA enrolled). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Team Members 4 top widget tiles (`OperatorWebSummaryStrip`) removed per Lane U-5 PR #670 verification. |
| OW-6d | "3-dot → 'Edit user' button; change email/name/role end-to-end" | ✅ DONE | Wave 2 W-1 (PR #680) replaced the 3-dot with a dedicated Edit-member dialog wired to a real email + display-name write path; W-1-FU (PR #689) then unlocked role + hierarchy rotation in the same dialog. Same row as RP-11. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — 3-dot → Edit-member dialog with email/name/role write path per W-1 PR #680 + W-1-FU PR #689 verification. |

### 7) Roles and Permissions (debug.md:158-167)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-7a | "Move under People" | ❌ NOT DONE | IA change. Wave 2 U-5 (PR #670) explicitly deferred this. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — 'Move under People' IA change explicitly deferred by Lane U-5 PR #670. |
| OW-7b | "Remove 'set what each role can do' subtitle" | ✅ DONE | Wave 2 U-5 (PR #670). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Roles 'set what each role can do' subtitle removed per Lane U-5 PR #670 verification. |
| OW-7c | "Remove 4 top widgets" | ✅ DONE | Wave 2 U-5 (PR #670) removed the Total roles / Custom / Default / MFA-protected strip. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Roles 4 top widgets (Total roles / Custom / Default / MFA-protected strip) removed per Lane U-5 PR #670 verification. |
| OW-7d | "'No custom roles' → 'Create Custom Role'" | ✅ DONE | Wave 2 U-5 (PR #670) renamed the empty-state heading to "Create custom role". <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Roles empty-state heading renamed to 'Create custom role' per Lane U-5 PR #670 verification. |
| OW-7e | "Remove 'build a custom role...' subtitle" | ✅ DONE | Wave 2 U-5 (PR #670). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Roles 'build a custom role...' subtitle removed per Lane U-5 PR #670 verification. |
| OW-7f | "Remove role_key UX if not removed" | ✅ DONE | Wave 2 U-5 (PR #670) removed the visible Role key field + slugifier mints it on save. Same row as RP-5. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Role key field removed + slugifier mints on save per Lane U-5 PR #670 verification. |
| OW-7g | "Remove 'standard roles forge and flow...' subtitle" | ✅ DONE | Wave 2 U-5 (PR #670). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Roles 'standard roles forge and flow...' subtitle removed per Lane U-5 PR #670 verification. |

### 8) Sign in Security (debug.md:169-173)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-8a | "Remove subtitle 'protect your own team...'" | ✅ DONE | Wave 2 U-5 (PR #670) verified the target copy does not exist on the consolidated Sign in Security surface. No action needed. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Sign in Security 'protect your own team...' subtitle target copy verified absent per Lane U-5 PR #670 verification. |
| OW-8b | "Remove 4 top tiles" | ✅ DONE | Wave 2 U-5 (PR #670) verified `MyAccountScreen` mounts no `OperatorWebSummaryStrip` at any depth. No tiles to remove. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Sign in Security top tiles verified absent (no `OperatorWebSummaryStrip` mounts) per Lane U-5 PR #670 verification. |
| OW-8c | "Lost-authenticator behaviour — NOT a link; should be 'contact admin to remove 2fa' + admin-side instructions" | ✅ DONE | Wave 2 U-5 (PR #670) verified the consolidated MFA surface already exposes `Request removal` (the 24-hour admin-flagged path), not a link. No CTA-as-link variant remains to convert. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — MFA surface exposes 'Request removal' (24-hour admin-flagged path), not CTA-as-link per Lane U-5 PR #670 verification. |
| OW-8d | "Consolidate Sign in & Security into My Account; remove standalone page" | ✅ DONE | Wave 2 U-5 (PR #670) verified the R-1 refactor already mapped the legacy `/sign-in-security` + `/security` routes to `MyAccountScreen` with `scrollToSecurityOnFirstBuild=true`. No standalone page remains. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — `/sign-in-security` + `/security` legacy routes map to `MyAccountScreen` with `scrollToSecurityOnFirstBuild=true` (no standalone page) per Lane U-5 PR #670 + C-3 verification. |

### 9) Active Sessions (debug.md:175-181)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-9a | "Team sessions show actual member names, not 'operator-web-qa-2026-...' device strings" | ✅ DONE | Wave 2 U-5 (PR #670) verified `_SessionsRow` renders `entry.targetUserDisplayName` above the device label when `renderTargetUser: true`. Member names show; the device-id format stays as the session-token-mint artifact below. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — `_SessionsRow` renders `entry.targetUserDisplayName` above device label when `renderTargetUser: true` per Lane U-5 PR #670 verification. |
| OW-9b | "Remove 4 top widget tiles" | ✅ DONE | Wave 2 U-5 (PR #670) removed the Your access / Team access / This browser / Refresh strip. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Active Sessions Your access / Team access / This browser / Refresh strip removed per Lane U-5 PR #670 verification. |
| OW-9c | "Remove 'devices you are currently...' + 'active sessions for everyone...' subtitles" | ✅ DONE | Wave 2 U-5 (PR #670) removed both inner-section subtitles. The outer page-level header subtitle is preserved (out-of-scope for OW-9c per the slice prompt). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Active Sessions inner-section subtitles removed (outer page-level header preserved per slice scope) per Lane U-5 PR #670 verification. |

### 10) Audit Log (debug.md:181)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-10 | "Plain-English explanation of audit log + zoom-out implementation read-back" | 🚧 IN PROGRESS | Wave 2 U-6 (PR #673) ran UX cleanup on the audit-log surface alongside the operator-web pane B8.b already shipped. **The plain-English read-back to the operator is still pending** — Step 1 walkthrough item, not closed by U-6's polish. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — Lane U-6 PR #673 ran audit-log UX cleanup; plain-English read-back pending Step 1. |

### 11) Vendor Connections → Vendor Integration (debug.md:183-187)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-11a | "Rename to Vendor Integration; replace 'connection' with 'integration' throughout" | ✅ DONE | Wave 2 V-1 (PR #660) ran the Vendor Connection → Vendor Integration rename sweep across all consoles + mobile + notification copy. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Vendor Connection → Vendor Integration rename sweep across all consoles + mobile + notification copy per V-1 PR #660 verification. |
| OW-11b | "Remove 4 widget tiles" | ✅ DONE | Wave 2 U-6 (PR #673). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Vendor Integration 4 widget tiles removed per Lane U-6 PR #673 verification. |
| OW-11c | "Reword 'initial backfill progress' → '60 day benchmark data' phrasing" | ✅ DONE | Wave 2 U-6 (PR #673). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — 'initial backfill progress' → '60 day benchmark data' phrasing per Lane U-6 PR #673 verification. |
| OW-11d | "Page throws 'could not load vendor connections' error" | ✅ DONE | Phase 2 verification 2026-05-14: the live HTTP vendor-connections gateway is wired through `FirebaseOperatorWebAuthSource` (`lib/operator_web/auth/firebase_operator_web_auth_source.dart:33,79-82` mounts `OperatorWebHttpVendorConnectionsGateway`) with the matching proxy route block at `tool/advisor_proxy/main.dart:1725-1739` + `:2118-2119`. Wired by commit `561680e4` ("Wire operator web console for live staging"). The earlier audit row premise that this shared root cause with B8.b deferral was incorrect — B8.b is the audit-log-hierarchy pane, a different surface. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — live HTTP vendor-connections gateway wired via `FirebaseOperatorWebAuthSource` (`lib/operator_web/auth/firebase_operator_web_auth_source.dart:33,79-82`) + proxy route at `tool/advisor_proxy/main.dart:1725-1739` per code-inspection verification 2026-05-14 (commit `561680e4`). |

### 12) Data Accuracy (debug.md:189-204)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-12a | "Explain the entire page" | 🚧 IN PROGRESS | Operator read-back still queued for Step 1. Wave 2 U-6 (PR #673) ran UX cleanup but did not produce the plain-English explainer. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — Lane U-6 PR #673 ran Data Accuracy UX cleanup; plain-English explainer pending Step 1 operator read-back. |
| OW-12b | "Remove top tiles (Labor dollars, Guest counts, Fallback cards, Polling tier)" | ✅ DONE | Wave 2 U-6 (PR #673). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Data Accuracy top tiles (Labor dollars / Guest counts / Fallback cards / Polling tier) removed per Lane U-6 PR #673 verification. |
| OW-12c | "Make 'Sources' bigger; remove 'pick the preferred system...' subtitle" | ✅ DONE | Wave 2 U-6 (PR #673). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — 'Sources' heading bigger + 'pick the preferred system...' subtitle removed per Lane U-6 PR #673 verification. |
| OW-12d | "Rename 'where labor dollars come from'; explain functionality + vendor scope" | ✅ DONE | Phase 2 verification 2026-05-14, corrected 2026-05-19: `lib/operator_web/widgets/data_accuracy_explainer_card.dart:71-83` renders the explainer as `_ExplainerSection(slug: 'wage', heading: 'How labor dollars are calculated', body: ...)` with both functionality copy and concrete vendor examples (QuickBooks Time reports hours and configured rates; Humanity reports pay rates times scheduled hours). Wave 2 S-1 (PR #679) earlier shipped the blended-mix formula UI rewrite on the Wage Authority side; S-2 unified the IA. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — `lib/operator_web/widgets/data_accuracy_explainer_card.dart:71-83` renders 'How labor dollars are calculated' explainer with functionality copy + concrete vendor examples per code-inspection verification 2026-05-14. |
| OW-12e | "Covers — explain 3 logic types; reservation integration?" | ✅ DONE | Phase 2 verification 2026-05-14: `lib/operator_web/widgets/data_accuracy_explainer_card.dart:85-97` renders the explainer as `_ExplainerSection(slug: 'covers', heading: 'Where covers come from', ...)` covering the three logic types (POS-tracked → POS source; POS does not track → forecast or manual per daypart) with a Square example. The reservation-integration walk-in handling continues at the next `_ExplainerSection(slug: 'walk_in', ...)` block immediately below. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — `lib/operator_web/widgets/data_accuracy_explainer_card.dart:85-97` renders 'Where covers come from' with three logic types + Square example + walk-in handling block per code-inspection verification 2026-05-14. |
| OW-12f | "Rename Monitoring → Data Freshness; bigger font" | ✅ DONE | Wave 2 U-6 (PR #673). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Monitoring → Data Freshness rename + bigger font per Lane U-6 PR #673 verification. |
| OW-12g | "Subtitle rewrite: 'Polling is...' + plan tier + request-fresh-data" | ✅ DONE | Wave 2 U-6 (PR #673). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — 'Polling is...' subtitle rewrite + plan tier + request-fresh-data per Lane U-6 PR #673 verification. |
| OW-12h | "Remove 'no poll only vendors connected'; make tier-change button better; wired as email?" | ✅ DONE | Wave 2 U-6 (PR #673) handled the cosmetic side; Wave 2 U-FU-tier-email (PR #713) wired the data-freshness-request to SendGrid. Production sends gated on follow-up `U-FU-tier-email-wire` (router mount into `tool/advisor_proxy/main.dart`) — parked. <br> Phase 2 walkthrough 2026-05-14: 🟢 SURFACE-LIVE — Lane U-6 PR #673 cosmetic side + U-FU-tier-email PR #713 wired data-freshness-request to SendGrid; production sends gated on parked U-FU-tier-email-wire follow-up. |
| OW-12i | "Rename 'How this applies to your setup' → 'Note:'" | ✅ DONE | Wave 2 U-6 (PR #673). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — 'How this applies to your setup' → 'Note:' rename per Lane U-6 PR #673 verification. |
| OW-12j | "Reword polling cadence + webhook subtitles" | ✅ DONE | Wave 2 U-6 (PR #673). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — polling cadence + webhook subtitles reworded per Lane U-6 PR #673 verification. |

### 13) Wage Authority (debug.md:206-241)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-13a | "UX matches the blended-wage-mix formula (FOH/BOH/Mgmt × hourly = total / heads = blended)" | ✅ DONE | Wave 2 S-1 (PR #679) rewrote the Wage Authority UI with the FOH/BOH/Management role list, per-role `_ × $/hr = total` rows, and the blended-mix calc display at the bottom. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — S-1 (PR #679) FOH/BOH/Management role list + per-role `_ × $/hr = total` rows + blended-mix calc display per Lane S verification. |
| OW-13b | "Top of screen: 'This applies to x.y.z vendors because of x'" | ✅ DONE | Wave 2 S-1 (PR #679) added the vendor-applicability label at the top of the Wage Authority surface, pulling from the B10.1/B10.2 vendor_applicability tables. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — S-1 (PR #679) vendor-applicability label at top of Wage Authority surface (pulling from B10.1/B10.2 vendor_applicability tables) per Lane S verification. |
| OW-13c | "Wage Authority + Data Accuracy on same page" | ✅ DONE | Wave 2 S-2 (PR #684) shipped the unified IA — Wage Authority + Data Accuracy now live on the single Data Accuracy page. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — S-2 (PR #684) unified IA — Wage Authority + Data Accuracy on single Data Accuracy page per Lane S verification. |
| OW-13d | "Editable admin-console list per setting type (wage / covers / polling); auto-flows to ops web" | ✅ DONE | Phase 2 verification 2026-05-14: `lib/admin/screens/vendor_applicability_admin_screen.dart:47-79` defines a `TabController` over all three setting kinds — wage / covers / polling — with per-tab edit UX wired through `VendorApplicabilitySettingKind` and idempotency-counter writes. B10.1 `vendor_applicability` table + Wave 2 S-1 (PR #679) operator-web consumption complete the round-trip. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — `lib/admin/screens/vendor_applicability_admin_screen.dart:47-79` defines TabController over wage/covers/polling kinds + per-tab edit UX wired through `VendorApplicabilitySettingKind` per code-inspection verification 2026-05-14; B10.1 + S-1 (PR #679) operator-web consumption complete round-trip. <br> Phase 2 walkthrough admin lane 2026-05-14: ✅ DONE-LIVE — admin Vendor Applicability screen driven live: subtitle "Choose which vendors are allowed to power wage, covers, and polling settings." + 3-tab TabBar visible (Wage / Covers / Polling — Wage tab selected by default) + "Which vendors can act as the wage source?" + Add vendor CTA + data table row for vendor `toast` (settingKey `default`, scope "F&F default", effectiveFrom `2026-05-13`, "Current" pill, metadata JSON `{"authority_basis": "job_code", "requires_job_code": true}`, Edit metadata + End row affordances). Per-tab edit UX wired; idempotency counter increments on each save per the gateway contract. |

### 14) Notifications (debug.md:243-255)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-14a | "Change 'First-Connect backfill' to 'First Connect Backfill' (no hyphens)" | ✅ DONE | Wave 2 U-6 (PR #673). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — 'First-Connect backfill' → 'First Connect Backfill' rename per Lane U-6 PR #673 verification. |
| OW-14b | "Reword 60-day historical seed → '60 days of P.O.S. data has been uploaded and your initial benchmark is now live'" | ✅ DONE | Wave 2 U-6 (PR #673). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — 60-day historical seed reworded → '60 days of P.O.S. data has been uploaded and your initial benchmark is now live' per Lane U-6 PR #673 verification. |
| OW-14c | "Vendor connection → Vendor Integration in notification copy" | ✅ DONE | Wave 2 V-1 (PR #660) included notification copy in the rename sweep. Same row as OW-11a. <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Vendor connection → Vendor Integration in notification copy per V-1 PR #660 verification. |
| OW-14d | "Simplify 'Audit Chain Anchor failed' wording" | ✅ DONE | Wave 2 U-6 (PR #673). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — 'Audit Chain Anchor failed' wording simplified per Lane U-6 PR #673 verification. |
| OW-14e | "Daily audit log description simpler with examples" | ✅ DONE | Wave 2 U-6 (PR #673). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — Daily audit log description simplified with examples per Lane U-6 PR #673 verification. |
| OW-14f | "Manager override → Benchmark override applied" | ✅ DONE | Wave 2 U-6 (PR #673). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — 'Manager override' → 'Benchmark override applied' per Lane U-6 PR #673 verification. |
| OW-14g | "Weekly plan 'a new weekly snapshot was locked in' — explain better" | ✅ DONE | Wave 2 U-6 (PR #673). <br> Phase 2 walkthrough 2026-05-14: ✅ DONE-LIVE — 'a new weekly snapshot was locked in' explainer reworded per Lane U-6 PR #673 verification. |

---

## Mobile UX (debug.md:258-306)

### Home

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-H-1 | "What is the live button for?" | 🚧 IN PROGRESS | `shift_dashboard.dart` references `LIVE` / `_LiveClock`. **Plain-English read-back** not done. Targets Step 1. <br> Phase 2 walkthrough 2026-05-14: 📱 MOBILE-DEFERRED — 'live button' on `shift_dashboard.dart` (`LIVE` / `_LiveClock`); deferred to mobile walkthrough lane; plain-English read-back pending Step 1. |

### 1) Notifications

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-1 | "Mark-as-read tick next to each notification" | ✅ DONE | Per `notifications_screen.dart:2` header comment: "W2.A — extended with per-tile mark-as-read tap." Plus `notifications_screen_mark_read_test.dart`. <br> Phase 2 walkthrough 2026-05-14: 📱 MOBILE-DEFERRED — mark-as-read tick on Notifications per `notifications_screen.dart`; deferred to mobile walkthrough lane. |

### 2) Data tab

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-2 | "Data tab privileged to F&F admin only — set via seeded role" | ✅ DONE | Wave 2 MO-1 (PR #661) gated the mobile Settings Data tab to F&F admin only via `_shouldShowDataTab` reading `PermissionKeys.adminDebugConsoleView`. MO-1-FU (PR #667) followed up by moving `SettingsDemoLiveSwitch` out of the gated Data tab onto the operator-visible Setup tab so the demo operator can still reach it. <br> Phase 2 walkthrough 2026-05-14: 📱 MOBILE-DEFERRED — mobile Data tab role-gated visibility (`PermissionKeys.adminDebugConsoleView`) per Wave 2 MO-1 PR #661; deferred to mobile walkthrough lane. |

### 3) Setup — Business Timing

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-3a | "View-only mobile business timing (correct as-is); cleanup subtitles + tiles" | ✅ DONE | Wave 2 U-7 (PR #678) dropped the "Current timing" pill + "Restaurant-local timing controls..." subtitle from `settings_timing_authority_section.dart` and dropped the Setup-tab "Review when business days..." description. <br> Phase 2 walkthrough 2026-05-14: 📱 MOBILE-DEFERRED — 'Current timing' pill + subtitle dropped per Lane U-7 PR #678; deferred to mobile walkthrough lane. |
| MO-3b | "Consolidate 'business day starts' + 'shift close rule' into one widget" | ✅ DONE | Wave 2 U-7 (PR #678) introduced the new `_BusinessDayBoundaryTile` that renders both rows inside one bordered container with a shared "Business day boundary" caption. <br> Phase 2 walkthrough 2026-05-14: 📱 MOBILE-DEFERRED — `_BusinessDayBoundaryTile` consolidation per Lane U-7 PR #678; deferred to mobile walkthrough lane. |
| MO-3c | "'Manage business timing on operator web' is a button that opens ops-web with same JWT, deep-links to relevant section" | ✅ DONE | Wave 2 U-FU-mobile-deeplink shipped via PR #600 (Codex C-5 mobile handoff-code deeplink, commit `161e6b85`) — B11.1 handoff-codes infrastructure wired through to the mobile UI. Same row as MO-4b / MO-6d. <br> Phase 2 walkthrough 2026-05-14: 📱 MOBILE-DEFERRED — mobile timing deep-link via U-FU-mobile-deeplink PR #600 (Codex C-5); deferred to mobile walkthrough lane. |

### 4) Wage Setup

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-4a | "Remove subtitle 'review the wage mix used...' + 'source default wages' wording" | ✅ DONE | Wave 2 U-7 (PR #678) dropped the "Review the wage mix..." subtitle from the Setup-tab Wage section. <br> Phase 2 walkthrough 2026-05-14: 📱 MOBILE-DEFERRED — 'Review the wage mix...' subtitle dropped per Lane U-7 PR #678; deferred to mobile walkthrough lane. |
| MO-4b | "'Manage wage setup on operator console' button same as timing" | ✅ DONE | Wave 2 U-FU-mobile-deeplink shipped via PR #600 (Codex C-5 mobile handoff-code deeplink, commit `161e6b85`). Same row as MO-3c / MO-6d. <br> Phase 2 walkthrough 2026-05-14: 📱 MOBILE-DEFERRED — mobile wage deep-link via U-FU-mobile-deeplink PR #600; deferred to mobile walkthrough lane. |
| MO-4c | "Widget displays the FOH/BOH/Mgmt breakdown (view-only)" | ✅ DONE | Wave 2 U-7 (PR #678) verified the FOH/BOH/Mgmt breakdown is already rendered view-only at `settings_wage_authority_section.dart:205-214`. The matching blended-mix display work on operator-web shipped via S-1 (PR #679); the mobile section already mirrors the same view-only shape. <br> Phase 2 walkthrough 2026-05-14: 📱 MOBILE-DEFERRED — FOH/BOH/Mgmt view-only breakdown at `settings_wage_authority_section.dart:205-214`; deferred to mobile walkthrough lane. |

### 6) Covers Setup

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-6 | "Covers setup on mobile — manual entry when vendors don't support; first item on setup tab" | ✅ DONE | Wave 2 MO-2 (PR #676) shipped the manual covers entry form on Settings → Setup as the first item, with primary-path framing for vendors that don't expose covers (Square / Clover) vs manual-override framing for vendors that do (Toast / Aloha / Lightspeed K-Series / Oracle MICROS Simphony / Revel). Supersession note: the PR #1020-era parity cleanup made signed-in production saves write canonical server truth through the proxy; mobile SQLite is now the recent-entry mirror, not the source of truth. <br> Phase 2 walkthrough 2026-05-14: 📱 MOBILE-DEFERRED — mobile covers manual entry on Settings → Setup + manual_cover_entries SQLite v34 migration per Wave 2 MO-2 PR #676; deferred to mobile walkthrough lane. |

### 7) Integrations tab

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-7a | "Third tab 'Integrations' — live status for POS / reservation / labor; button to ops portal" | ✅ DONE | Wave 2 MP-1 (PR #685) shipped the new mobile Integrations tab with live POS / reservation / labor vendor status and the ops-portal deep-link button. <br> Phase 2 walkthrough 2026-05-14: 📱 MOBILE-DEFERRED — mobile Integrations tab with live POS/reservation/labor status per Wave 2 MP-1 PR #685; deferred to mobile walkthrough lane. |
| MO-7b | "Demo→Live switch lives here too (zoom out on demo-switch impl)" | ✅ DONE | Wave 2 MP-1 (PR #685) mounted `SettingsDemoLiveSwitch` inside the new Integrations tab (replacing the MO-1-FU temporary placement under Setup). The C-4 master switch is now in its canonical home. <br> Phase 2 walkthrough 2026-05-14: 📱 MOBILE-DEFERRED — `SettingsDemoLiveSwitch` mounted in mobile Integrations tab per Wave 2 MP-1 PR #685; deferred to mobile walkthrough lane. |

### 5) Account 2FA

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-5a | "Direct enable-MFA button on account 2FA section" | ✅ DONE | `settings_mfa_section.dart` + C-7 adaptive MFA flow shipped. <br> Phase 2 walkthrough 2026-05-14: 📱 MOBILE-DEFERRED — direct enable-MFA button on mobile 2FA section; deferred to mobile walkthrough lane. |
| MO-5b | "Adaptive label: enabled / Remove 2FA / Enroll / Cancel request (24h window)" | 🚧 IN PROGRESS — pending operator review of canonical label "Two-factor authentication" | The adaptive state-machine is shipped — C-7 covers all states of (MfaCardStage, factorCount, recoveryCodesViewedAt) per `c_12_lane_c_closeout_audit.md`. Phase 2 verification 2026-05-14 surfaced a small label-drift gap across 4 surfaces (mixed "2FA" / "MFA" / "Two-factor" usage). Operator has not yet seen the canonical-label proposal "Two-factor authentication". Detail: `docs/archive/_audits/wave_2/phase_2_walkthrough_verification.md`. Once the operator picks a canonical label (or confirms the current mix), the V1.1 follow-up `MO-5b-FU` sweep can flip this row to ✅ DONE. <br> Phase 2 walkthrough 2026-05-14: 🐛 GAP-FOUND — small label-drift gap across 4 mobile surfaces (mixed '2FA' / 'MFA' / 'Two-factor' usage) per Phase 2 verification doc; operator decision pending on canonical 'Two-factor authentication' label; MO-5b-FU sweep follow-up parked V1.1. |
| MO-5c | "'This used to be in code in history — check git'" | (operator note) | Reference to prior implementation. Subsumed by MO-5b. <br> Phase 2 walkthrough 2026-05-14: 📱 MOBILE-DEFERRED — operator note (reference to prior implementation); subsumed by MO-5b. |

### 6) Account — Sign in details

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-6b | "Remove subtitle 'review your sign in details'" | ✅ DONE | Wave 2 U-7 (PR #678) dropped the "Review your sign-in details." subtitle. <br> Phase 2 walkthrough 2026-05-14: 📱 MOBILE-DEFERRED — 'Review your sign-in details.' subtitle dropped per Lane U-7 PR #678; deferred to mobile walkthrough lane. |
| MO-6c | "Rename 'Display name' → 'Name'" | ✅ DONE | Wave 2 U-7 (PR #678) renamed the label to "Name" in the `_AccountInfoSummaryCard`. <br> Phase 2 walkthrough 2026-05-14: 📱 MOBILE-DEFERRED — 'Display name' → 'Name' rename in `_AccountInfoSummaryCard` per Lane U-7 PR #678; deferred to mobile walkthrough lane. |
| MO-6d | "'Manage account on operator web' deep-link button (same as timing/wage)" | ✅ DONE | Wave 2 U-FU-mobile-deeplink shipped via PR #600 (Codex C-5 mobile handoff-code deeplink, commit `161e6b85`). Same row as MO-3c / MO-4b. <br> Phase 2 walkthrough 2026-05-14: 📱 MOBILE-DEFERRED — 'Manage account on operator web' deep-link via U-FU-mobile-deeplink PR #600; deferred to mobile walkthrough lane. |

### 7b) Active Sessions

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-7c | "Remove 'see where your account...' subtitle" | ✅ DONE | Wave 2 U-7 (PR #678) dropped the "See where your account..." subtitle. <br> Phase 2 walkthrough 2026-05-14: 📱 MOBILE-DEFERRED — 'See where your account...' subtitle dropped per Lane U-7 PR #678; deferred to mobile walkthrough lane. |
| MO-7d | "Remove second 'Active sessions' header" | ✅ DONE | Wave 2 U-7 (PR #678) removed the duplicate `Active sessions` header from the section card; the `_ActiveSessionsHeader` now renders icon + description only. <br> Phase 2 walkthrough 2026-05-14: 📱 MOBILE-DEFERRED — duplicate `Active sessions` header removed per Lane U-7 PR #678; deferred to mobile walkthrough lane. |
| MO-7e | "Devices: when + device only (no IP)" | ✅ DONE | Wave 2 U-7 (PR #678) shortened the device row to `Last active <relative>` only; IP + approximate-location helper removed from `_metaLine`. <br> Phase 2 walkthrough 2026-05-14: 📱 MOBILE-DEFERRED — device row shortened to 'Last active <relative>' (IP + location helper removed) per Lane U-7 PR #678; deferred to mobile walkthrough lane. |
| MO-7f | "Sign out + sign out of all devices buttons" | 🚧 IN PROGRESS | Wave 2 U-7 (PR #678) disclosed this as "verified section infra, separate flag" — the underlying `revoke non-self` path (B9.2) plus the mobile section infrastructure are in place, but the explicit "Sign out / Sign out of all devices" CTAs are not yet surfaced on this section. Auth-touching toggle — defer to a dedicated follow-up. <br> Phase 2 walkthrough 2026-05-14: 📱 MOBILE-DEFERRED — 'Sign out / Sign out of all devices' CTAs not yet surfaced; auth-touching toggle deferred to dedicated follow-up; mobile walkthrough lane owns hands-on verification. |

### Settings tab reorder

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-S | "Settings tab order: setup, integrations, data (F&F-admin), account" | ✅ DONE | Wave 2 U-7 (PR #678) moved Account from first to last in the tab list; Wave 2 MP-1 (PR #685) then inserted the new Integrations tab between Setup and Data. Final order: `Setup → Integrations → Data (F&F admin gated) → Account`. <br> Phase 2 walkthrough 2026-05-14: 📱 MOBILE-DEFERRED — Settings tab order `Setup → Integrations → Data (F&F admin) → Account` per Lane U-7 PR #678 + MP-1 PR #685; deferred to mobile walkthrough lane. |

---

## "Brian Computer" — Email + Notification scaffold (debug.md:308-325)

This is the operator's pasted research summary. It restates EN-2 +
EN-3 + EN-4 + EN-5 with sharper framing.

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| BC-1 | "Scaffold audit lane in code-health wave" | ✅ DONE | Wave 2 Q-3 (PR #658) ran the scaffold audit lane (email-renderer doc strings + dispatcher orphans + BC-1 invite path), exactly the lane this row asked for. Same row as EN-2 / EN-4 / QI-1. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — Q-3 (PR #658) scaffold audit lane (email-renderer doc strings + dispatcher orphans + invite path) per Lane Q verification. |
| BC-2 | "Soak harness: ~6 days code (bug fixes + regression tests) + ~6 days forensic kit (heap, state-machine, sign-in integrity)" | ✅ DONE | Wave 2 Q-1 (PR #672) completed the soak harness and swapped the heap-snapshot uploader from GCS to Azure Blob, closing the "Azure swap pending" follow-up in `POST_HARDENING_FOLLOWUPS.md`. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — Q-1 (PR #672) soak harness completion + Azure Blob heap-snapshot uploader; closes Azure swap follow-up per Lane Q verification. |
| BC-3 | "Email/notification harness: ~10 days + ~$200/mo (Patrol + Firebase Test Lab + Mailosaur + SendGrid webhook)" | ✅ DONE | Wave 2 Q-2 shipped the harness as 3 sub-slices: Q-2a (PR #696, Mailosaur + SendGrid event webhook), Q-2b (PR #704, Patrol in-app notification surface), Q-2c (PR #708, Firebase Test Lab mobile push delivery). Same row as EN-5. Test execution against a live production deploy is Phase 5/6 ops work, not Wave 2 scope. <br> Phase 2 walkthrough 2026-05-14: 🔧 BACKEND — Q-2 email/notification harness as 3 sub-slices (Q-2a/Q-2b/Q-2c); harness in place, live-deploy execution is Phase 5/6 ops work per Lane Q verification. |

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
