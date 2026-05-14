# Phase 2 walkthrough — master plan

> **Created 2026-05-14 evening.** Owner: orchestrator. Purpose: hold the
> Phase 2 walkthrough state across multiple sessions so nothing is lost
> mid-flight or due to context boundaries.
>
> **Read this top to bottom on every session restart.** The Status
> board below is the source of truth for what's done, what's next, and
> what's blocked.

---

## Continuation prompt (paste into a fresh session to resume)

```
You are resuming the Phase 2 walkthrough verification per
`docs/_audits/wave_2/phase_2_walkthrough_master_plan.md`. Read that
file top to bottom before anything else. The Status board at the top
tells you which console lane is active and the next concrete action.

The rolling evidence matrix lives at
`docs/_audits/wave_2/phase_2_walkthrough_verification.md`. Update it
inline as you go (do not write an "appendix" — annotate the existing
matrix tables).

Workflow per console lane (operator-web → admin → mobile):
 1. Drive every surface in the lane's surfaces-to-drive list. Use the
    two dev-only patches (web/index.html CSP relax + lib/main_operator_web.dart
    initial-state skip-onboarding) per the markers in this master plan
    when driving the operator-web lane. Revert before any commit.
 2. Sweep all relevant rows in the three trackers (WAVE_2_LEDGER,
    WAVE_EXECUTION_LEDGER, DEBUG_MD_IMPLEMENTATION_STATUS) and append
    an inline one-line annotation per row, not a single changelog
    entry. Format: `Phase 2 walkthrough 2026-05-14: <state> — <evidence>`.
 3. Demo-fidelity bugs you find LIVE get fixed live — either spawn a
    worktree agent (`isolation: worktree`, contract = branch → fix →
    self-audit → commit → push → open PR → STOP) or inline in this
    branch if the edit is < 20 LoC and operator hasn't said "no auto-fix".
 4. UX-decision gaps (e.g. 3-dot vs inline button, scope-flip demo
    behaviour) get filed as parked rows in WAVE_2_LEDGER and the Gaps
    Filed table in this master plan, NEVER auto-fixed.
 5. After each meaningful slice of work, commit + push. Update the
    Status board in this master plan before the commit.
 6. Hand off to operator only when the lane's acceptance criteria are
    all met OR you need an operator decision.

Use the `window.__ff` helper from §"Helper scripts" below to drive
Flutter web clicks after enabling semantics via the flt-semantics-
placeholder click. Flutter web text inputs ignore programmatic .value
writes — use the skip-onboarding patch to avoid the welcome→token
typing requirement.

Worktree agents must NEVER merge, NEVER use --no-verify, NEVER update
trackers themselves. Orchestrator audits + merges only.

Read `CLAUDE.md` for the authority order, the Hard Promises, and the
workflow. Read `docs/_audits/audit_chunking_playbook.md` if a chunk
gets big enough to warrant sub-agents.

Stop only when: a console lane is fully done AND committed, OR you
need an operator decision (file the question, do not guess).
```

---

## Status board (update on every commit)

| Lane | Owner | State | Last commit | Next action |
|---|---|---|---|---|
| **Operator-web** | Main Claude (this lane) | ✅ **DONE** — Round 3 (2026-05-14 evening 2) closed the deferred set: U-1 sign-out drove demo source signOut → Welcome (live login screen code-anchored, filed U-1-FU-demo-needs-signin-emission DEFER V1.1); OW-8c MFA-enrolled drove "MFA: Enrolled" badge + "View recovery codes" CTA live via session.mfaEnrolled patch (deeper Request-removal sub-states code-anchored, filed OW-8c-FU-demo-gateway-pending-removal DEFER V1.1); OW-4 inverse + RP-15 cap code-anchored per gaps register defer dispositions. All patches reverted. PR #741 lands Round 2 closure + Claude2 handoff + walkthrough docs on master. Subsequent rounds (PRs #744–#749) closed all 9 parked V1.1 follow-ups via worker agents. | `63e262b9` (PR #741 merge, 2026-05-14 evening 2) | Hand off to admin console (Claude2 lane) + mobile (pending operator instruction). |
| **Admin console** | Claude2 lane | ✅ DONE — round 2 closed 2026-05-14 late evening. AC-1 source fixes shipped at commit `04bf3be4` (canonical labels unified on "Team member" + "Service account" per operator decision; `team.session.force_logout` chip now reads "Signed out a team member session"; 50 tests pass; analyze clean). Round 2 walkthrough drove 8 of 9 deferred surfaces live: admin sign-in card (signed-out boot, no skip patch) / Roles+Hierarchy+Sessions Access route (2-tab, not 3-tab — Sessions are inside Security/audit/sessions) / Vendor connections per-location subview (Toronto Yorkville drill) / Default Role Catalog Add role + draft editor / Audited support actions Actions panel WITH live AC-1 fix verification ("Team member" + "Service account" + "Signed out a team member session" all rendering correctly) / Operator-switch flip Demo Diner Co. ↔ Sunset Cafe Group / RP-9 ff_support read-only spot-check (read-only banner + Add role CTA absent confirmed live) / Top-bar scope flip per-route. 1 surface code-anchored (Support workspace per-location button didn't expose in viewport). 3 gaps RESOLVED via this round (`AC-1-FU-admin-actor-kind-catalog-drift`, `AC-1-FU-team-session-force-logout-label`, `RP-9-FU-ff-support-readonly-spot-check`). 2 gaps remain open as V1.1 demo-polish carry-overs (`RP-15-FU-admin-demo-override-fixture`, `MO-5b-FU-admin-my-account`) + 1 new low-priority gap filed (`Support-FU-admin-walkthrough`). | `claude2/admin-walkthrough-phase-2` (commits `a46d3d2a` round 1 docs + `04bf3be4` AC-1 source fix + this round-2 closeout). PR: [forge-flow-demo#743](https://github.com/SaidKhan005/forge-flow-demo/pull/743) | Lane CLOSED. Operator action: review + merge PR #743. Optional spot-check the 1 remaining code-anchored surface (Support workspace) if desired. V1.1 follow-ups: RP-15-FU-admin-demo-override-fixture + MO-5b-FU-admin-my-account (paired with Main's MO-5b-FU-operator-web) + Support-FU-admin-walkthrough. |
| **Mobile (Samsung A54 R5CW503HJHP)** | Main Claude (this lane) | ⏸ PENDING | — | After operator-web lane closes. Need forgeflow APK build + adb install + demo seed. |

### Cross-lane coordination

Append a one-line note here whenever a cross-lane event happens that the other lane needs to know about. Format: `<date>: <lane> — <event>`.

- 2026-05-14 evening: Main opened Claude2 handoff doc for admin console lane. Claude2 takes over admin lane on a separate machine. Concurrency rule: Main never edits `lib/admin/**`; Claude2 never edits `lib/operator_web/**` or `lib/main_forgeflow.dart`. Shared docs (master plan + verification matrix + trackers) get per-lane sections; both lanes annotate their own tracker rows inline, never overwrite each other's annotations.
- 2026-05-14 evening 2: Main merged Claude2 handoff + Round 2 walkthrough closure into master via PR #741 (commit `63e262b9`). Claude2 can now `git pull origin master` on the second machine and pick up `docs/_indices/PHASE_2_WALKTHROUGH_CLAUDE2_HANDOFF.md` + the master plan + the verification matrix.
- 2026-05-14 evening 2: Main closed operator-web lane via Round 3 (U-1 + OW-8c live; OW-4 inverse + RP-15 cap code-anchored). 2 new V1.1 follow-up rows filed (U-1-FU-demo-needs-signin-emission, OW-8c-FU-demo-gateway-pending-removal). Operator-web Status flipped to ✅ DONE.
- 2026-05-14 evening 3: Main closed 9 parked V1.1 follow-ups via 5 PRs (#744 OW-12j+RP-1, #745 OW-6d, #746 B-FU-dev-csp, #747 MO-5b operator-web+admin, #748 demo-fidelity bundle). One new follow-up filed: **MO-5b-FU-mobile-recanonicalize** (mobile PR #735 shipped "Two-factor authentication"; operator-web + admin PR #747 now ships "Two-factor sign-in" canonical → mobile divergent, queue as first mobile slice when lane is green-lit). Demo walkthroughs no longer need hand-applied CSP patches — use `scripts/run_operator_web_dev.ps1` + `--dart-define=OPERATOR_WEB_DEMO_SCENARIO=<scenario>` per the new scenario catalog at `lib/operator_web/demo/operator_web_demo_scenario.dart`.
- 2026-05-14 evening: Claude2 round 1 closed. Admin matrix appended to `phase_2_walkthrough_verification.md`. 4 new admin gaps filed in this master plan's Gaps register (`AC-1-FU-admin-actor-kind-catalog-drift`, `AC-1-FU-team-session-force-logout-label`, `RP-15-FU-admin-demo-override-fixture`, `MO-5b-FU-admin-my-account` extends Main's `MO-5b-FU-operator-web`). Heads-up to Main: the AC-1 admin findings show the canonical `ActorKindLabelCatalog` at `lib/services/auth/actor_kind_label_catalog.dart` is only consumed by an orphan widget (`audit_log_admin_screen.dart` not mounted in any route); the LIVE admin audit-log surface uses a parallel enum's labels. If Main is touching operator-web audit-log surfaces for the AC-1 / MO-5b sweep, the same canonical-label decision (`Team member` vs `Operator member`, `Automated service` vs `Service account`) will need to bind both consoles. Admin lane dev patches (CSP relaxation on `web/index.html` + skip-sign-in on `lib/main_admin.dart` flipping `signedOut()` → `signedInAsSuperAdmin()`) reverted before the round-1 commit; tree clean. Windows-only quirk: `flutter run` on Windows 11 Home needs Developer Mode enabled OR `--no-pub` flag (skips the symlink-required plugin synthesis step). Filing as a method postmortem — not a gap because the worktree booted under `--no-pub`. Coordination ask: none. Round 2 will drive the 9 deferred click-paths (admin sign-in card / Roles+Hierarchy+Sessions / Vendor connections per-location / Support workspace / Default Role Catalog publish dialog / Audited support actions modals).
- 2026-05-14 late evening: Claude2 admin lane CLOSED. Operator picks 2026-05-14: (1) canonical actor_kind labels = **"Team member" + "Service account"**; (2) ship both AC-1 fixes; (3) drive the 9 deferred surfaces with Developer Mode on. All 3 directives complete. AC-1 source fixes shipped at commit `04bf3be4` (6 files: catalog + admin gateway + admin screen + 3 test files; 50 tests pass; analyze clean). Round 2 walkthrough drove 8 of 9 deferred surfaces live + verified both AC-1 fixes are rendering correctly on the live admin audit-log surface (filter chips + row body + force-logout chip label all canonical). 3 gaps RESOLVED (`AC-1-FU-admin-actor-kind-catalog-drift`, `AC-1-FU-team-session-force-logout-label`, `RP-9-FU-ff-support-readonly-spot-check`). 2 gaps remain open as V1.1 demo-polish carry-overs (`RP-15-FU-admin-demo-override-fixture` + `MO-5b-FU-admin-my-account` paired with Main's `MO-5b-FU-operator-web`). 1 new low-priority gap filed (`Support-FU-admin-walkthrough`). **Cross-lane heads-up to Main**: the canonical label decision now binds both consoles via `ActorKindLabelCatalog.byKind`. The operator-web side picks up "Team member" + "Service account" automatically because `audit_log_hierarchy_filter_pane.dart` reads the same catalog. The 1 affected operator-web test (`audit_log_hierarchy_filter_pane_test.dart:325-329`) was updated in the same commit to assert the new canonical labels. No source-code change to operator-web surfaces; this was a test-fixture-only operator-web edit, fully justified by the shared-catalog change. Lane status: ✅ DONE. PR: [forge-flow-demo#743](https://github.com/SaidKhan005/forge-flow-demo/pull/743).

---

## Operator-web lane

### Surfaces to drive (live)

Tick as each is driven and matrix-annotated.

#### Done in `c92d8a9a` (Lane U + V matrix commit)
- [x] Top bar (OW-0c) — scope selector, role chip, sign-out, branding
- [x] Business Account (U-3 + U-FU-hp11-account + OW-2b/c/d/e/f/g + W-5 + W-6)
- [x] Business Setup (U-4 + OW-3a/b/d/f/g + H-2 inheritance tree + HP #11 effective-value)
- [x] My account (U-5 + W-3 + OW-5b/d/8d + Two-factor card)
- [x] Team members (U-5 + OW-6a/b/c + W-2 cancel invite)
- [x] Roles & permissions (U-5 + S-3 list + OW-7b-g)
- [x] Custom role editor (S-3 + R-1L human_label + R-2L MFA badges + Q-4 scope filter)
- [x] Active sessions (U-5 + OW-9a/b/c)
- [x] Audit log (U-6 + OW-10 + B8.b filter + B8 anchor status)
- [x] Vendor integrations (U-6 + V-1 + OW-11a/b/c/d + HP #2 demo badges)
- [x] Data accuracy (U-6 + OW-12a-i + S-1 wage authority + S-2 unified IA + OW-13a/b/c)
- [x] Notifications (U-6 + OW-14a-g)
- [x] Schedule (OW-1 + H-1)
- [x] OW-4 location-scope half (no Locations item in nav at location scope)

#### Remaining to drive

##### Done in round 2 (2026-05-14 evening)
- [x] **Permission Explainer screen** — ✅ DONE-LIVE. Renders 106 permission keys grouped by 10 productLabels (Product access / Forge & Flow / Barrio / F&F admin / Team self-service / Account configuration / Business timing / Billing / Integrations per vendor / Integrations vendor connections / Workflows Phase 12). Each row carries key + human_label + MFA badge where required. 🐛 GAP `RP-1-FU-permission-key-human-labels` filed (4 newer keys missing human_label).
- [x] **W-1 + W-1-FU Edit-member dialog body** — ✅ DONE-LIVE. Drove via pixel-coord click on the overlay menu. Dialog header "Edit member" + explainer "Change this teammate's email, name, role, or hierarchy scope. The change writes to Firebase + audit log; the operator will see the change in their audit log." Field set: Email + Display name + Role (Owner) + Hierarchy scope (Business-wide, with "Business-wide: this teammate can act in every location." helper) + Reason field + Cancel + Save.
- [x] **RP-15 scope-flip on Benchmarks** — 🟢 SURFACE-LIVE. Clicked Downtown in tree → override card flipped from "Demo Restaurant Group / 4.58 / Target cycle" to "Downtown / 4.58 / Target cycle". Tree+card wiring works. Cap state-machine deferred to Manager-role demo session (filed `RP-15-FU-cap-state-manager-session`).
- [x] **OW-12j polling cadence subtitle copy diff** — 🐛 GAP-FOUND. Operator-requested literal strings ("Polling and data freshness applies to..." / "Vendors outside this list update in real time...") NOT rendered verbatim. Shipped copy ("F&F controls how often we ask your poll-only vendors..." / "Webhook vendors are real-time regardless.") is arguably better but doesn't match the literal ask. Filed `OW-12j-FU-copy-decision`.

##### Done in Round 3 (2026-05-14 evening 2)
- [x] **U-1 post-sign-out path** — drove `Sign out` live. Demo source emits `OperatorWebSignedOut` which the router maps to Welcome (NeedsToken), NOT the live Login screen. Live Login screen is owned by `FirebaseOperatorWebAuthSource` (`OperatorWebNeedsSignIn` state) and code-anchored in `lib/operator_web/screens/login_screen.dart`. Filed **U-1-FU-demo-needs-signin-emission** to add a demo-source variant that emits NeedsSignIn on signOut (DEFER V1.1).
- [x] **OW-8c MFA-enrolled** — drove the CTA shift live via `session.mfaEnrolled: true` dev patch. Verified: "MFA: Enrolled" badge + headline "Save your recovery codes" + "1 method is enrolled" body + "View recovery codes" CTA. Matches `MfaCardStage.enrolled` + `!recoveryCodesViewed` at [mfa_card_controller.dart:330-344](lib/operator_web/account/mfa_card_controller.dart:330). Deeper "Request removal" + "Cancel request" sub-states code-anchored at [my_account_screen.dart:313-345](lib/operator_web/screens/my_account_screen.dart:313) + [mfa_card_controller.dart:376-392](lib/operator_web/account/mfa_card_controller.dart:376) (require `DemoWebSecurityGateway` pending-removal seeding to exercise live — filed **OW-8c-FU-demo-gateway-pending-removal** DEFER V1.1).
- [x] **OW-4 business-scope inverse** — code-anchored at [operator_web_router.dart:989-995](lib/operator_web/router/operator_web_router.dart:989) (`if (!isLocationScope) const OperatorWebNavItem(... title: 'Locations' ...)`). Live drive deferred per existing **OW-4-FU-business-scope-demo** (OPERATOR DECISION — defer V1.1).
- [x] **RP-15 manager-once cap state** — code-anchored at [benchmarks_screen.dart:187-198](lib/operator_web/screens/benchmarks_screen.dart:187) (cap rejection translates `manager_override_cap_reached` envelope to operator-facing copy). Live drive deferred per existing **RP-15-FU-cap-state-manager-session** (DEFER — code-anchored + tested).

### Tracker annotation status — operator-web lane scope

Phase 1 (changelog-only entry) DONE in commit `c92d8a9a`. Phase 2 (inline annotation per row) DONE via PR #739 (`2e2f03aa`, merged to master via PR #741 at `63e262b9`).

- [x] **DEBUG_MD_IMPLEMENTATION_STATUS.md** — ~148 rows inline-annotated (DONE-LIVE 104, SURFACE-LIVE 7, BACKEND 120, ADMIN-DEFERRED 10, MOBILE-DEFERRED 30, GAP-FOUND 2, NOT-DRIVEN 1).
- [x] **WAVE_2_LEDGER.md** — 33 rows inline-annotated.
- [x] **WAVE_EXECUTION_LEDGER.md (Wave 1)** — Wave 1 Lane A + Lane B backbone rows operator-web-visible annotated.

### Gaps filed (master gap register)

| ID | Title | Source surface | Severity | Disposition | Status |
|---|---|---|---|---|---|
| `R-2L-FU-demo-fixture` | Operator-web demo `kDemoTeamRolesFixture` still seeds v1 5-role list, not v2 10-role catalog from R-2L PR #711 | Roles & permissions list | Demo-fidelity (cosmetic) | **FIX LIVE** (worktree agent) | ✅ **RESOLVED** via PR #740 (2026-05-14 evening). |
| `U-FU-hp11-account-demo-defaults` | "Inherits from Business: null / null" + "Business: null:00 local" string interpolation leak on Account scope notices + brand-new-operator path | Business Account → Region / Business week sections | Demo-fidelity + production brand-new-operator path | **FIX LIVE** | ✅ **RESOLVED** via PR #738 (2026-05-14 evening). |
| `MO-5b-FU-operator-web` | Two-factor sign-in / MFA / 2FA label drift extends to operator-web. Surfaces: My account Two-factor card; Audit log Action filter chips ("MFA enrolled (authenticator)" / "MFA factor removed" vs canonical "Reset two-factor sign-in") | My account, Audit log | Demo + production-copy (operator-facing) | **FIX LIVE** (operator picked "Two-factor sign-in" canonical) | ✅ **RESOLVED** via PR #747 → merged to master at `3c7bb384` (2026-05-14 evening 3). Operator-web + admin sweep landed: badges flipped to "Two-factor sign-in: Off / Enabled / Removal pending / Ready to turn off"; audit log chips flipped to "Two-factor sign-in enabled / disabled / setup failed / recovery requested"; admin "Reset MFA" → "Reset two-factor sign-in" across audited support + members admin + my account admin. |
| `OW-6d-FU-edit-button-UX` | Operator's debug.md 156 literal ask was "instead of the 3 dot icon is should be a button saying edit user" | Team members row trailing | UX decision | **OPERATOR DECISION** (operator picked "inline Edit button + smaller overflow for destructive actions") | ✅ **RESOLVED** via PR #745 → merged to master at `ed2725c9` (2026-05-14 evening 3). Row now renders inline `TextButton.icon("Edit")` + smaller 32×32 overflow `PopupMenuButton` holding only the 4 destructive actions (Suspend / Reactivate / Reset password / Reset two-factor sign-in / Remove from team). |
| `OW-4-FU-business-scope-demo` | Demo session is location-pinned via `kDemoOperatorWebSession.primaryLocationId='demo-location'`; the top-bar scope selector renders the H-3 tree but selecting "All locations / Business-wide" is a no-op | Top-bar selector | Demo-fidelity (walkthrough-only) | **OPERATOR DECISION** (operator picked umbrella demo-fidelity bundle) | ✅ **RESOLVED** via PR #748 → merged to master at `d8c270c8` (2026-05-14 evening 3). `--dart-define=OPERATOR_WEB_DEMO_SCENARIO=owner-business` now drives the OW-4 inverse case live; `kDemoOperatorWebBusinessSession` ships with `primaryLocationId: null`; router fallback logic gates Locations nav on `null && trim().isNotEmpty`. |
| `B-FU-dev-csp` | Production CSP in `web/index.html` blocks Flutter dev DDC bootstrap; walkthrough requires a dev-only `unsafe-inline` + `unsafe-eval` carve-out applied + reverted per session | `web/index.html` CSP | Infra (developer-experience) | **OPERATOR DECISION** (operator picked build-time CSP swap via deploy script) | ✅ **RESOLVED** via PR #746 → merged to master at `58efc20f` (2026-05-14 evening 3). `scripts/deploy_operator_web.ps1 -DevDdc` (typed-confirmation-gated) + new `scripts/run_operator_web_dev.ps1` (try/finally restore + idempotent crash recovery) replace the hand-applied + reverted patch flow. Production CSP unchanged on disk; swap is build-time only. |
| `RP-1-FU-permission-key-human-labels` | Permission Explainer renders machine keys instead of descriptions for `team.roles.default_catalog.edit` + `team.roles.default_catalog.view` (original 4-key list was over-broad — `team.users.self_update` + `integrations.configure` already had correct descriptions) | Permission Explainer screen | Operator-visible bug | **FIX LIVE** (operator picked "ship my proposals") | ✅ **RESOLVED** via PR #744 → merged to master at `2a4f9b3b` (2026-05-14 evening 3). 2 missing descriptions added verbatim from migration `202605150300_phase_rp_9_default_catalog_edit_permission_key.sql` per parity contract anti-paraphrase rule. |
| `OW-12j-FU-copy-decision` | Data accuracy → "What this page is for" + Data freshness tier card uses operator-friendly + concrete copy but NOT the exact debug.md 197-199 literal strings | `data_accuracy_explainer_card.dart` | Copy decision — shipped is arguably better than literal | **OPERATOR DECISION** (operator picked hybrid: literal + short why) | ✅ **RESOLVED** via PR #744 → merged to master at `2a4f9b3b` (2026-05-14 evening 3). New copy: "Polling and data freshness applies to your poll-only vendors. F&F checks them on a schedule so your dashboard stays as live as the schedule. Vendors outside this list update in real time because they push data to F&F as it happens." |
| `RP-15-FU-cap-state-manager-session` | RP-15 manager-once override cap state-machine cannot be exercised live because demo session is Owner | `kDemoOperatorWebSession` role binding | Walkthrough fidelity | **DEFER → umbrella demo-fidelity bundle** | ✅ **RESOLVED** via PR #748. `--dart-define=OPERATOR_WEB_DEMO_SCENARIO=manager-once` switches the demo source to `kDemoOperatorWebLocationManagerSession` for the cap walkthrough. |
| `U-1-FU-demo-needs-signin-emission` | Demo source maps `signOut → SignedOut → NeedsToken → Welcome` instead of `SignedOut → NeedsSignIn → live LoginScreen` | `DemoOperatorWebAuthSource.signOut` + new initial-state factory | Walkthrough fidelity | **DEFER → umbrella demo-fidelity bundle** | ✅ **RESOLVED** via PR #748. `--dart-define=OPERATOR_WEB_DEMO_SCENARIO=signed-out-live` flips `_emitNeedsSignInOnSignOut: true` so signOut emits `OperatorWebNeedsSignIn` and the live `OperatorWebSignInScreen` renders. |
| `OW-8c-FU-demo-gateway-pending-removal` | OW-8c deeper sub-states (`MfaCardStage.removalRequested` "MFA: Removal requested" + countdown copy; `MfaCardStage.removable` "MFA: Ready to turn off") cannot be exercised live because `DemoWebSecurityGateway` does not seed pending-removal state | `DemoWebSecurityGateway.fetchMfaState()` seeding | Walkthrough fidelity | **DEFER → umbrella demo-fidelity bundle** | ✅ **RESOLVED** via PR #748. New `DemoWebSecurityGateway.seedPendingFactorRemoval()` helper + `--dart-define=OPERATOR_WEB_DEMO_SCENARIO=mfa-pending-removal` seeds the gateway with an 18h pending removal on first paint. |
| `MO-5b-FU-mobile-recanonicalize` (new 2026-05-14 evening 3) | Mobile MO-5b (PR #735) shipped "Two-factor authentication" as the mobile canonical; operator-web + admin MO-5b (PR #747) shipped "Two-factor sign-in" as the V1 canonical. Mobile is now divergent and needs a re-sweep so every two-factor surface across operator-web + admin + mobile uses one consistent phrase | mobile audit log filter chips + 2FA labels in `lib/services/auth/auth_operations_gateway.dart` + mobile screens | Production-copy (operator-facing, cross-surface consistency) | **FIX-LIVE candidate** (mobile mirror of PR #747 sweep) | open — file as first slice when mobile lane is green-lit |
| `AC-1-FU-admin-actor-kind-catalog-drift` (filed 2026-05-14 evening, admin lane) | Wave 2 AC-1 canonical `ActorKindLabelCatalog` was consumed ONLY by orphan `lib/admin/screens/audit_log_admin_screen.dart`; the LIVE admin audit-log surface used `AuditActorKind.displayLabel` with drifting labels. | `lib/admin/services/audited_support_actions_admin_gateway.dart:110-119` (drifting enum); live consumer at `audited_support_actions_admin_screen.dart:1526,1672` | Operator-facing copy drift | ✅ **RESOLVED** via commit `04bf3be4` (2026-05-14 late evening, landed in PR #743). Operator picked canonical labels "Team member" + "Service account"; `ActorKindLabelCatalog.byKind` updated for service/service_principal; `AuditActorKind.displayLabel` now delegates to `ActorKindLabelCatalog.labelFor(wire)` so both consoles share one source. 50 tests pass; `flutter analyze` clean. Verified live in round 2 walkthrough (audit row body + filter chips read the new canonical labels). |
| `AC-1-FU-team-session-force-logout-label` (filed 2026-05-14 evening, admin lane) | The `team.session.force_logout` action chip on the admin Security/audit/sessions audit-log filter rendered the machine key as its own description. | `lib/admin/screens/audited_support_actions_admin_screen.dart` action chip catalog | Operator-visible bug (Audit log filter looked broken on that one row) | ✅ **RESOLVED** via commit `04bf3be4` (2026-05-14 late evening, landed in PR #743). `humanizeAuditAction()` at `audited_support_actions_admin_screen.dart:1644-1650` now maps `team.session.force_logout` → "Signed out a team member session" (mirrors operator-web's `WebTeamAuditLogGateway.humanLabelFor` at `web_team_audit_log_gateway.dart:214-215`). Verified live in round 2 walkthrough. |
| `RP-15-FU-admin-demo-override-fixture` (new 2026-05-14 evening, admin lane) | Admin Covers and Wage Data Accuracy (RP-15 admin-undo path) cannot be exercised live in the current demo fixture — Demo Diner Co. has no existing override seeded, so the audit history is empty ("0 events / No admin overrides recorded yet.") and the undo state-machine cannot be driven | `_defaultDataAccuracyAdminGateway` seed block in `lib/admin/admin_routes.dart` | Walkthrough fidelity (admin parallel of operator-web's `RP-15-FU-cap-state-manager-session`) | DEFER — code-anchored at the per-location screen + the gateway interface | open — defer |
| `MO-5b-FU-admin-my-account` (new 2026-05-14 evening, admin lane; extends Main's `MO-5b-FU-operator-web`) | Admin My Account Security section mixes 3 labels in one card: "2FA is required..." (header) + "Two-step verification" (section heading) + "two-factor sign-in" (body) — same MO-5b drift Main flagged on operator-web My Account. Audit log action chips on the admin Security/audit/sessions surface ARE internally consistent ("MFA" everywhere) but the My Account headers drift against both | `lib/admin/screens/my_account_admin_screen.dart` Security section | Operator-facing copy drift | OPERATOR-DECISION pending canonical label (bundled with Main's existing `MO-5b-FU-operator-web` open question — same label catalog, same operator answer drives both consoles) | open — operator decision pending |

### Acceptance criteria for "operator-web lane done"

1. ✅ All driven surfaces in the matrix.
2. ✅ All demo-fidelity bugs marked FIX LIVE either fixed (PR merged) or filed with explicit operator-deferral note.
3. ✅ All UX-decision gaps captured in WAVE_2_LEDGER as parked rows awaiting operator.
4. ✅ All operator-web-relevant rows in all 3 trackers inline-annotated.
5. ✅ Dev patches reverted; tree clean; final commit + push.
6. ✅ Master plan Status board flipped to ✅ DONE; "next action" = "hand off to admin console lane".

---

## Admin console lane

### Surfaces to drive

(To be populated after operator-web lane closes. Seed list:)

- [x] Admin sign-in screen — ✅ round 2: rendered live via signed-out boot (F&F brand mark + email/password card + "Sign in" CTA + "F&F internal access only." footer); 3 fixture identities code-anchored at `admin_auth_gate.dart:255-273`. Sign-in click-through blocked by Flutter web text-input ignore (operator manual spot-check covers it).
- [x] Admin top bar / operator switcher — ✅ live (F&F logo + Admin Console + Ecosystem admin role pill + identity chip + Sign out); operator-switch flip Demo Diner Co. ↔ Sunset Cafe Group ✅ round 2.
- [x] Admin Health (`health_admin_screen.dart`) — ✅ QI-8 3-tab tile rendering driven live (Advisor data / App service / Ecosystem)
- [x] Admin Default Role Catalog (`default_role_catalog_admin_screen.dart`) — ✅ RP-9 permission gate confirmed via super_admin path; ff_support read-only branch driven live round 2 (read-only banner "View only: ecosystem admin access is required to publish a new default catalog version." + Add role CTA hidden)
- [x] Admin Default Role Catalog publish dialog (`default_role_catalog_publish_dialog.dart`) — 🟢 round 2: Add role flow drove the draft editor live (role_key + display_name + description + permission picker); publish dialog itself blocked by Flutter web text-input (can't fill role_key + display_name to enable Publish). Operator manual spot-check covers the modal open path.
- [x] Admin My Account (`my_account_admin_screen.dart`) — ✅ W-4 parity driven live (3 sections: Identity + Security + Active sessions)
- [x] Admin Members (`members_admin_screen.dart`) — ✅ W-1 admin side driven live (4 members + 1 pending invite + filters)
- [x] Admin Invite member (`invite_member_admin_dialog.dart`) — ✅ RP-10 hierarchy-tree picker driven live (same copy as operator-web)
- [x] Admin Audit log (`audit_log_admin_screen.dart`) — 🔧 ORPHAN, NOT MOUNTED. Standalone widget exists but not wired to any admin route (grep confirms). The LIVE admin audit log is inside `audited_support_actions_admin_screen.dart`. Round 2 verified the AC-1 fix end-to-end on the live surface ("Team member" / "Service account" / "Signed out a team member session" all rendering correctly).
- [x] Admin Audited support actions (`audited_support_actions_admin_screen.dart`) — ✅ round 1: AC-1 actor_kind drift caught + filed. ✅ round 2: AC-1 fix verified live (audit row + filter chips both render canonical labels) + Actions panel driven (Reset MFA / Send reset email / Issue erasure CTAs visible). Modal click-paths code-anchored via test suite.
- [x] Admin Vendor applicability (`vendor_applicability_admin_screen.dart`) — ✅ OW-13d 3-tab editor (Wage / Covers / Polling) driven live
- [x] Admin Vendor connections (`vendor_connections_admin_mount.dart`) — ✅ round 2: location-scope drill verified live (Toronto Yorkville path); empty-state at business scope + location-scope disclosure card rendered with full hierarchy banner.
- [x] Admin Per-location data accuracy (`per_location_data_accuracy_screen.dart`) — 🟢 surface live; RP-15 admin-undo not exercisable (no override seeded — filed `RP-15-FU-admin-demo-override-fixture`)
- [x] Admin Roles + Hierarchy + Sessions (`roles_hierarchy_sessions_admin_screen.dart`) — ✅ round 2: Access route driven live via Members → Role policy CTA. Page title "Access" + scope-context tile triplet (4 seeded / 1 custom / 106 permissions) + Role policy tab with full seeded-role + custom-role + permission-catalog rendering. **Discovery**: route is actually 2-tab (Role policy + Location hierarchy), NOT 3-tab — Sessions are inside `audited_support_actions_admin_screen.dart` per the team-access card copy "Active sessions moved to Security/audit/sessions."
- [x] Admin Polling + pricing (`polling_and_pricing_admin_screen.dart`) — ✅ driven live (tier definitions + tier assignments + margin rollup)
- [x] Admin Pricing tier (`pricing_tier_admin_screen.dart`) — ✅ driven live (Plans and limits, plan presets, usage limits)
- [x] Admin Corpus (`corpus_admin_screen.dart`) — ✅ driven live (Knowledge base + current version + content pieces)
- [x] Admin Debug console (`debug_console_admin_screen.dart`) — ✅ Support logs driven live (5 demo log rows + 4 request-type labels from `admin_human_labels.dart`)
- [x] Admin Feature flags (`feature_flags_admin_screen.dart`) — 🟢 Launch controls driven live (4 seeded flags + Enable/Disable affordances)
- [x] Admin Integration (`integration_admin_screen.dart`) — ✅ Connected services driven live (Service Access + Vendor connector catalog grouped by operational system)
- [x] Admin Observability (`observability_admin_screen.dart`) — ✅ AI Metrics driven live (scope-aware copy + Run metrics check CTA + cross-link to System health)
- [x] Admin Operator picker (`operator_picker_screen.dart`) — ✅ driven live as part of Business accounts route (2 seeded operators)
- [x] Admin Operator location (`operator_location_admin_screen.dart`) — ✅ Demo Diner Co. detail card driven live (2 locations, hierarchy actions, inner-nav tile grid)
- [ ] Admin Support operator view (`support_operator_view_admin_screen.dart`) — 🔧 code-anchored only after rounds 1 + 2. Route id at `admin_routes.dart:290` + per-location "Support view" button at `operator_location_admin_screen.dart:3326-3334`. The location-row action panel didn't expose as a clickable semantic-tree leaf in either walkthrough viewport. Filed `Support-FU-admin-walkthrough` low-priority — operator manual spot-check covers it.
- [x] Admin Timing setup (`admin_timing_setup_screen.dart`) — ✅ driven live (HP #11 triad + effective timing + service periods)

### Admin launch reference

```
scripts/run_admin_console_dev.ps1 -DemoMode
```

This runs `flutter run -t lib/main_admin.dart -d chrome --dart-define=ADMIN_DEMO_AUTH=true` per `run_admin_console_dev.ps1:43-55`. Fixture login users available: `super.admin@`, `support@`, `operator@` (see `_resolveAuthSource` in `main_admin.dart`).

For Claude Preview MCP, swap `-d chrome` for `-d web-server --web-port=8182 --web-hostname=0.0.0.0` to bind a queryable URL.

### Acceptance criteria same shape as operator-web.

---

## Mobile lane (Samsung A54, deviceId `R5CW503HJHP`)

### Prereq

- [ ] `flutter build apk --debug --flavor forgeflow -t lib/main_forgeflow.dart --dart-define=ANTHROPIC_API_KEY=$env:ANTHROPIC_API_KEY` (or use `scripts/run_flutter_dev.ps1 -App forgeflow -Device R5CW503HJHP -UseFirebaseAuth`)
- [ ] `adb install` the resulting APK to the Samsung
- [ ] Confirm demo seed flows (mock replay)

### First slice (queued from operator-web lane closeout, 2026-05-14 evening 3)

- [ ] **MO-5b-FU-mobile-recanonicalize** — Mirror PR #747's operator-web + admin sweep on the mobile side. Mobile PR #735 shipped "Two-factor authentication"; V1 canonical is now "Two-factor sign-in". Drop into a worktree agent on the first mobile lane session; mirrors the PR #747 sweep scope (badge strings, audit-log action labels, body copy) against `lib/services/auth/auth_operations_gateway.dart` + mobile screens. Do this **before** driving mobile MO-5a/b/c surfaces so the walkthrough copy matches what operators see in operator-web + admin.

### Surfaces to drive

(To be populated after admin lane closes. Seed list — from debug.md 257-306 + MP-1 + MO-* ledger rows:)

- [ ] Home screen — MO-H-1 live button explainer
- [ ] Notifications tab — MO-1 mark-as-read tick
- [ ] Data tab — MO-1 (renamed MO-2 in debug.md) F&F-admin-only gating
- [ ] Setup tab — Business timing MO-3a/b/c (view-only + cleanup + operator-web deeplink)
- [ ] Wage Setup — MO-4a/b/c
- [ ] Covers Setup — MO-2 / MO-6 manual entry + reservation fallback
- [ ] Integrations tab — MP-1 (live status + demo-live switch + ops-portal deeplink)
- [ ] Account → 2FA — MO-5a/b/c
- [ ] Account → Sign-in details — MO-6b/c/d
- [ ] Account → Active Sessions — MO-7c/d/e/f
- [ ] Settings tab order — MO-S (Setup → Integrations → Data → Account)
- [ ] U-FU-mobile-deeplink handoff-code flow

### Mobile screenshot pattern

`$adb shell screencap -p /sdcard/screen.png && $adb pull /sdcard/screen.png` — pull each surface as PNG, save under `docs/_audits/wave_2/phase_2_walkthrough_evidence/mobile/<surface>.png`.

### Acceptance criteria same shape.

---

## Dev-only patches reference

> **Superseded 2026-05-14 evening 3.** The manual patch flow below is
> retired. Use the new tooling shipped via PR #746 + PR #748 instead:
>
> ```
> # Local walkthrough (any scenario):
> pwsh scripts/run_operator_web_dev.ps1 -- --dart-define=OPERATOR_WEB_DEMO_SCENARIO=owner-location-completed
>
> # OW-4 inverse:        --dart-define=OPERATOR_WEB_DEMO_SCENARIO=owner-business
> # U-1 live login:      --dart-define=OPERATOR_WEB_DEMO_SCENARIO=signed-out-live
> # OW-8c enrolled:      --dart-define=OPERATOR_WEB_DEMO_SCENARIO=mfa-enrolled
> # OW-8c pending rmvl:  --dart-define=OPERATOR_WEB_DEMO_SCENARIO=mfa-pending-removal
> # RP-15 manager cap:   --dart-define=OPERATOR_WEB_DEMO_SCENARIO=manager-once
> ```
>
> The dev-run helper backs up `web/index.html` to
> `web/index.prod.html.bak`, swaps in the dev-relaxed CSP for the
> duration of the run, and restores from backup on exit (Ctrl-C,
> error, or normal completion). Idempotent: if a previous run was
> killed mid-flight, the next invocation restores from backup before
> applying the dev CSP again, so the source tree never carries a stale
> dev CSP. Cloud Run deploys do NOT pick up the dev CSP unless you
> explicitly pass `-DevDdc` to `scripts/deploy_operator_web.ps1` AND
> type the confirmation phrase at the warning prompt.
>
> The historical patches below are preserved for archival reference
> only.

### Patch 1 — CSP relaxation (`web/index.html`)

Replace the production CSP `<meta>` tag (matches `'sha256-LEIgqV9+9hWnNcFZ7vYClnAB0Fj6CI1idm4CgGmnQ5g='`) with:

```html
<!-- DEV-ONLY CSP RELAXATION (Phase 2 walkthrough 2026-05-14, REVERT BEFORE COMMIT) -->
<meta http-equiv="Content-Security-Policy" content="
  default-src 'self' 'unsafe-inline' 'unsafe-eval';
  script-src 'self' 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval' https://www.gstatic.com https://*.firebaseapp.com;
  style-src 'self' 'unsafe-inline' https://fonts.googleapis.com;
  img-src 'self' data: blob: https:;
  font-src 'self' data: https://fonts.gstatic.com;
  connect-src 'self' ws://localhost:* http://localhost:* https://www.gstatic.com https://fonts.gstatic.com https://*.googleapis.com https://*.firebaseio.com https://*.cloudfunctions.net wss://*.firebaseio.com https://admin-proxy.forgeflow.app https://*.forgeflow.app https://*.run.app;
  frame-src 'self' https://*.firebaseapp.com;
  object-src 'none';
  base-uri 'self';
  form-action 'self';
">
```

### Patch 2 — Skip onboarding (`lib/main_operator_web.dart`)

In `_DemoOperatorWebAuthSourceWithTeamSurfaces`, change:

```dart
super(initial: const OperatorWebNeedsToken());
```

to:

```dart
// DEV-ONLY (Phase 2 walkthrough 2026-05-14, REVERT BEFORE COMMIT):
// Skip onboarding and land directly on the authenticated app shell.
super(initial: const OperatorWebCompleted(session: kDemoOperatorWebSession));
```

### Patch 3 (apply when driving OW-4 business-scope inverse)

Patch `kDemoOperatorWebSession` in `lib/operator_web/auth/operator_web_auth_source.dart`:

```dart
// DEV-ONLY: business-scope variant for OW-4 inverse-case drive.
const OperatorWebSession kDemoOperatorWebBusinessSession = OperatorWebSession(
  uid: 'demo-operator-owner',
  email: 'owner@demo.forgeflow.test',
  displayName: 'Demo Operator Owner',
  operatorId: 'demo-operator',
  businessName: 'Demo Restaurant Group',
  primaryLocationId: null,   // <-- the key change
  // (preserve other fields from kDemoOperatorWebSession)
);
```

Then point `_DemoOperatorWebAuthSourceWithTeamSurfaces` at the business
variant for the inverse-case drive.

### Patch 4 (apply when driving OW-8c MFA-enrolled state)

Edit `DemoWebTeamUsersGateway` or `DemoWebSecurityGateway` (in
`lib/operator_web/services/demo_team_*_gateway.dart`) to seed the demo
Owner with at least one enrolled MFA factor — see existing test fixture
`demo-mfa-factor-owner-totp` referenced in
`demo_team_audit_log_gateway.dart` for the shape.

### .claude/launch.json

Gitignored. Required entries:

```json
{
  "version": "0.0.1",
  "configurations": [
    {
      "name": "operator-web-demo",
      "runtimeExecutable": "flutter",
      "runtimeArgs": [
        "run", "-d", "web-server", "--web-port=8181",
        "--web-hostname=0.0.0.0",
        "-t", "lib/main_operator_web.dart",
        "--dart-define=OPERATOR_WEB_DEMO_AUTH=true"
      ],
      "port": 8181
    },
    {
      "name": "admin-console-demo",
      "runtimeExecutable": "flutter",
      "runtimeArgs": [
        "run", "-d", "web-server", "--web-port=8182",
        "--web-hostname=0.0.0.0",
        "-t", "lib/main_admin.dart",
        "--dart-define=ADMIN_DEMO_AUTH=true"
      ],
      "port": 8182
    }
  ]
}
```

---

## Boot procedure — operator-web

```
1. Apply Patch 1 + Patch 2 (and Patch 3 / Patch 4 if the surfaces-to-drive
   list calls for them).
2. preview_start name="operator-web-demo".
3. Bash poll: `until curl -sf http://localhost:8181/main_module.bootstrap.js >/dev/null; do sleep 3; done`.
4. preview_screenshot (page shows splash).
5. preview_eval the manual loader invocation:
       (async () => {
         await window._flutter.loader.load({
           onEntrypointLoaded: async (init) => {
             const appRunner = await init.initializeEngine();
             await appRunner.runApp();
           }
         });
       })()
6. Wait ~30-45s for DDC modules to evaluate (705 .lib.js files).
7. preview_eval: click flt-semantics-placeholder to enable semantics.
8. Install __ff helper (see Helper scripts).
9. Drive surfaces.
```

---

## Helper scripts

### `window.__ff` click helper (paste into preview_eval after semantics enabled)

```js
window.__ff = {
  enableSem() {
    const ph = document.querySelector('flt-semantics-placeholder');
    if (ph) ph.click();
  },
  findNav(label) {
    const nodes = Array.from(document.querySelectorAll('flt-semantics'));
    const m = nodes.filter(n => (n.textContent||'').includes(label) && n.children.length === 0);
    if (!m.length) return null;
    m.sort((a,b) => (a.textContent||'').length - (b.textContent||'').length);
    return m[0];
  },
  clickRect(rect) {
    const glass = document.querySelector('flt-glass-pane');
    if (!glass) return false;
    const x = rect.left + rect.width/2, y = rect.top + rect.height/2;
    const opts = { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y, button: 0, pointerType: 'mouse', isPrimary: true, pointerId: 1 };
    glass.dispatchEvent(new PointerEvent('pointerdown', opts));
    glass.dispatchEvent(new MouseEvent('mousedown', opts));
    glass.dispatchEvent(new PointerEvent('pointerup', opts));
    glass.dispatchEvent(new MouseEvent('mouseup', opts));
    glass.dispatchEvent(new MouseEvent('click', opts));
    return { x, y };
  },
  clickXY(x, y) { return this.clickRect({ left: x - 1, top: y - 1, width: 2, height: 2 }); },
  async clickNav(label) {
    this.enableSem();
    await new Promise(r => setTimeout(r, 300));
    const t = this.findNav(label);
    if (!t) return { ok: false, reason: 'not found' };
    const r = t.getBoundingClientRect();
    const res = this.clickRect(r);
    await new Promise(r => setTimeout(r, 800));
    return { ok: true, click: res, label };
  },
  async snapshot() {
    this.enableSem();
    await new Promise(r => setTimeout(r, 400));
    const nodes = Array.from(document.querySelectorAll('flt-semantics'));
    return nodes.filter(n => n.children.length <= 2)
      .map(n => (n.textContent||'').trim())
      .filter(t => t.length > 0 && t.length < 120);
  }
};
```

### Notes on Flutter web automation quirks

- **CanvasKit + semantic tree**: clicks on `flt-semantics` nodes themselves DON'T fire Flutter's pointer router. Always dispatch on `flt-glass-pane` at the bounding-rect center.
- **Overlay menus (popup_menu / dropdown items)**: dropdown overlay items are NOT in the semantic tree. Read pixel coordinates from a screenshot and use `__ff.clickXY(x, y)`.
- **Text inputs**: `input.value = '…'` + `dispatchEvent('input')` is IGNORED by Flutter's TextEditingController. `document.execCommand('insertText', …)` also ignored. The walkthrough avoids typing via the skip-onboarding patch; if a surface absolutely needs text entry, the fix is to drive a real KeyboardEvent at each character through the engine — much slower, kept as last resort.
- **`location.href` does not change** on nav. Operator-web router renders on auth state, not URL paths. Don't try `navigate()`-style routing.

---

## Workflow checklist (paste-friendly per session)

```
[ ] 1. Open this master plan; read top to bottom.
[ ] 2. Run `git status` — expect clean tree.
[ ] 3. Open `phase_2_walkthrough_verification.md` — confirm matrix state.
[ ] 4. Confirm Status board's "next action" still matches reality.
[ ] 5. Re-apply Patch 1 + Patch 2 (any others called for).
[ ] 6. preview_start operator-web-demo.
[ ] 7. Wait for bootstrap; run manual loader; enable semantics; install __ff.
[ ] 8. Drive the next [ ] surface from the lane's surfaces-to-drive list.
[ ] 9. Record evidence in the matrix (in the verification doc).
[ ]10. If a demo-fidelity bug surfaces — fix inline (<20 LoC) OR spawn
       worktree fix agent (>=20 LoC); add row to the Gaps register.
[ ]11. If a UX-decision gap surfaces — file as parked row in WAVE_2_LEDGER
       + add to Gaps register; ask operator before next session.
[ ]12. After 3-6 surfaces, refresh the matrix + master plan Status board.
       Revert dev patches, commit, push. Update commit hash in Status board.
[ ]13. Loop back to step 8 until lane is empty.
[ ]14. When lane is empty AND all acceptance criteria pass, flip lane to
       ✅ DONE in Status board, mark next lane's "next action".
[ ]15. Hand off to operator only if a UX decision is required, or the
       lane is fully done.
```

---

## Worktree agent contract (for fix agents + annotation agents)

Spawn with `isolation: worktree`. Each agent's prompt should be self-
contained and follow this contract:

```
Branch off the orchestrator's current branch.
Apply the canonical hooks: `pwsh scripts/install_git_hooks.ps1`.
Make the specific edit listed below.
Self-audit with file:line citations (Pattern B half-table).
Commit + push + open PR. NEVER merge. NEVER --no-verify. NEVER edit trackers.
Reply with PR number + Pattern B self-audit table + STOP.
```

Annotation agents get a per-tracker prompt template; fix agents get the
specific bug + the matrix evidence as context.

---

## Acceptance criteria for "Phase 2 walkthrough done" (all three lanes)

- All three Status board lanes flipped to ✅ DONE.
- Every operator-web-visible + admin-visible + mobile-visible row in
  WAVE_2_LEDGER + WAVE_EXECUTION_LEDGER + DEBUG_MD_IMPLEMENTATION_STATUS
  carries an inline `Phase 2 walkthrough <date>: <state> — <evidence>`
  annotation.
- Every demo-fidelity bug surfaced either has a merged fix PR OR is
  parked with explicit operator-deferral note.
- Every UX-decision gap is filed as a parked row awaiting operator
  decision.
- Dev patches reverted; tree clean.
- Operator signs off + tags `happy-state-<date>`.
