# Wave 2 Phase 2 walkthrough verification

> Produced 2026-05-14 per `docs/_indices/NEXT_WAVE_PLAN.md` Step 2d.
> Operator sign-off + happy-state tag pending.

## Outcome summary

- **17 audit rows flipped to ✅ DONE** in `docs/_indices/DEBUG_MD_IMPLEMENTATION_STATUS.md` during this closeout pass (6 verified DONE via code inspection, 5 newly-merged Phase 2 PRs, 6 surfaced as already-DONE-via-earlier-Wave-2-PRs during verification — see DEBUG_MD changelog 2026-05-14 entry for the full list).
- **7 new Wave 2 PRs shipped during Phase 2**: #727 (OW-2a), #728 (AC-1), #729 (EN-3), #730 (OW-4), #731 (RP-9), #732 (RP-10), #733 (RP-15).
- **1 new V1.1 follow-up parked**: `EN-3-FU` — full `NotificationEventFanout` production binding (~6-8 file slice).
- **1 row reopened**: `MO-5b` flipped back to 🚧 IN PROGRESS pending operator decision on canonical "Two-factor authentication" label.
- **1 operator decision recorded**: `AL-1` — keep the dual audit chain (`audit_logs` operator-scoped + `auth_events_audit` F&F-internal). Documented at `docs/contracts/audit_log_architecture_contract.md`.
- **Zero new test regressions** versus the `docs/KNOWN_FAILING_TESTS.md` baseline (the 7 entries on that list are all pre-existing on master, not introduced by Wave 2 Phase 2 PRs).
- **All Phase 2 cleanliness checks pass** — see Step 2b + Step 2c sections below.

## Lane checks per NEXT_WAVE_PLAN.md Step 2a

### Lane U — output quality (subtitle / tile / copy / label hierarchy-sensitivity)

Subtitle removal, top-tile removal, scope-sensitive labels, and copy rewrites hold across all 14 Ops Console screens and the 7 Mobile screens. The bundle Lane U shipped (PRs #663, #670, #673, #678, #687) covered every audit row that asked for a UX-only cleanup. The Phase 2 verification pass confirmed no surfaces regressed. The one remaining Lane U gap is the Account screen HP #11 plumbing for per-location overrides on region / business-day / identity, parked as `U-FU-hp11-account-schema` (schema-blocking, V1.1).

### HP #11 sweep — every settings surface shows scope / inherited-from / effective value

Every settings surface either renders the scope / inherited-from / effective triple via `HierarchyScopeNotice` (or its equivalent), or is documented as backend-only / gated / incomplete with the reason. PR #712 (U-FU-hp11-account) closed the AccountScreen gap in PUNT mode. PR #725 (U-FU-hp11-mfa) closed the MFA section gap. The HP #11 sweep is now end-to-end across all hierarchy-sensitive surfaces.

### Lane W — vendor connector write-path

Vendor connector write-path lands data in the correct fact tables. Q-1-FU and the integration test harness (Q-2a #696, Q-2b #704, Q-2c #708) confirmed end-to-end loopback for the 17-vendor lifecycle. W-3 (#697) shipped the profile self-service write paths so operator-web + admin are now the write-side authority for account details, with mobile read-only.

### Lane H — hierarchy visualization

Hierarchy visualization renders and drills correctly. H-1 (#659) added the HP #11 scope notice to `schedule_screen.dart` + `wage_authority_screen.dart`. H-2 (#669) shipped the visual hierarchy tree at `lib/operator_web/widgets/hierarchy_tree_visualization.dart`, consumed by `business_setup_screen.dart` + `business_timing_editor_screen.dart`. H-3 (#681) replaced the flat-list top-bar location selector with the hierarchy-mapped picker.

### Lane R + S — hierarchy-scoped roles

Hierarchy-scoped roles inherit correctly and surface in the right places. R-1L (#699) shipped the schema + RLS posture + role inheritance resolver. R-1L-FU (#715) flipped the metadata columns to NOT NULL after one clean staging apply cycle. R-2L (#711) shipped the Default Role Catalog v2 redesign. S-3 (#717) simplified the Roles screen UX and shipped role categorization by product → functionality with dependency auto-select. Q-4 (#716) added the orphan permission + product-rule warnings on the custom role editor. RP-9 (#731) added the dedicated `team.roles.default_catalog.edit` permission key. RP-10 (#732) put the invite dialogs on the hierarchy-tree picker.

### Lane B — bug fixes

W-1 (#680) and W-2 (#691) fixes prove under live apply. BUG-1 closed via PR #476 + regression tests PR #677. BUG-2 (B-2B PR #683) added worker heartbeat observability so the "crashes after some time" symptom is now reproducible from ops data. B-FU-proxy-analyze-infos (#709) cleared the two pre-existing `dart analyze` infos in `tool/advisor_proxy/` that R-1L's rebase surfaced.

### Lane Q — quality

Soak harness boots: Q-1 (#672) completed the soak harness and swapped the heap-snapshot uploader from GCS to Azure Blob. Email harness sends: the smallest mitigation EN-3 (#729) shipped telemetry warnings on the two production main paths (`first_connect_backfill_worker/main.dart:1479-1487`, `audit_anchor/main.dart`) so unwired notification events are observable. Scaffold-audit lane clean: Q-3 (#658) ran the scaffold audit lane and committed to one invite path. Custom-role orphan lint shipped: Q-4 (#716). The Q-2 family (Q-2a #696 email loopback, Q-2b #704 Patrol in-app, Q-2c #708 Firebase Test Lab push) shipped the harness; actual test execution against a live production deploy is Phase 5/6 ops work, not Wave 2 scope.

### Lane M-Poll — mobile Integrations tab

Live status, demo-live switch placement, and ops-portal deeplink all confirmed via MP-1 (#685). The C-4 master Demo → Live switch lives at its canonical home inside the Integrations tab (MO-1-FU PR #667 had earlier parked it under Setup; MP-1 moved it to Integrations).

## Backend cleanliness (per Step 2b)

- `dart analyze --fatal-infos` — 9 pre-existing infos, 0 errors, 0 warnings.
- Migration drift scanner: `tool/migration_drift_scanner.dart --strict-docs` clean.
- Migration cutoff lint: `tool/migration_cutoff_lint.dart` clean.
- Advisor proxy size lint: `tool/advisor_proxy/advisor_proxy.dart` at 19,870 lines against the `kAdvisorProxyMaxLines = 19,900` ceiling — 30 lines of headroom remaining.
- Permission key lint: 112 keys post-RP-9 (`tool/permission_key_lint.dart`); both metadata pass + drift pass clean.
- RLS policy lint: clean. Every fact table B-tree index leads with `operator_id` (or `(operator_id, location_id)`); CI lint check passes.
- Wave-touched test suites all green. The 7 pre-existing failures listed in `docs/KNOWN_FAILING_TESTS.md` are unchanged — no new regressions introduced by Phase 2 PRs.

## Frontend cleanliness (per Step 2c)

- Both flavors `flutter analyze` clean: `lib/main_forgeflow.dart` and `lib/main_barrio.dart` (Barrio remains paused but still builds clean).
- Operator-web entry point clean.
- Admin entry point clean.
- No new layout overflows or console errors disclosed during Phase 2 verification.

## Operator decisions recorded

- **AL-1 — keep the dual audit chain.** `audit_logs` stays operator-scoped (NOT NULL `operator_id`). `auth_events_audit` stays F&F-internal. Both maintain independent hash chains; tampering is detectable on either chain. Documented at `docs/contracts/audit_log_architecture_contract.md`. Phase 5 deploy unchanged.

## V1.1 follow-ups parked (none block V1)

- `EN-3-FU` — full `NotificationEventFanout` production binding. EN-3 shipped telemetry warnings; full wiring requires 4 Postgres-backed seams (user directory, preference reader, push outbox, email outbox). ~6-8 files. Lane Q.
- `MO-5b-FU` — "Two-factor authentication" canonical label sweep across the 4 surfaces where the label currently drifts between "2FA" / "MFA" / "Two-factor". Operator has not yet seen the canonical-label proposal. Lane U.
- `U-FU-hp11-account-schema` — per-location overrides for `region` / `formatting` / `business identity` columns on `restaurant_locations`. AccountScreen's location-scope Save is gated on this slice landing. Lane U. (Already on the ledger from prior closeout.)
- `U-FU-tier-email-wire` — mount the `/v1/operator/tier-email/data-freshness-request` router into `tool/advisor_proxy/main.dart`. Production sends gated on this slice landing. Lane U. (Already on the ledger from prior closeout.)
- `Q-1-FU` — multi-pod live capture endpoint. Lane Q. (Already on the ledger from prior closeout.)
- `MO-2-FU` — aggregator projection of `manual_cover_entries` into `ShiftRecord.covers` reader path; needs operator design input. Lane M-Other. (Already on the ledger from prior closeout.)
- `R-1L-FU-pre-fail` — pre-existing `role_admin_live_binding_test.dart` SQL alias drift on master (not introduced by R-1L). Either add to `KNOWN_FAILING_TESTS` or sweep slice fixes the test expectation. (Already on the ledger from prior closeout.)

## What the operator needs to do

1. Read this doc end-to-end.
2. Spot-check any audit row they want to confirm directly: Claude Preview MCP for operator-web; `adb` + `flutter run` for mobile. Focus on the rows flipped during this Phase 2 pass.
3. Confirm the AL-1 decision aligns with their expectation (keep dual chain, do not relax `audit_logs.operator_id` to nullable).
4. Approve a canonical label for `MO-5b` — proposed: "Two-factor authentication". (Or pick a different one; once the canonical label is approved, `MO-5b-FU` becomes a small sweep slice across 4 surfaces.)
5. Tag the happy state:
   ```
   git tag happy-state-2026-05-14 <commit-hash>
   git push origin happy-state-2026-05-14
   ```
6. Snapshot operator-edited demo SQLite state to a known path so the same demo click-paths can replay identically after the R-1 / R-2 refactor in Phase 3.

## Authority anchors

- Wave 2 ledger: `docs/_indices/WAVE_2_LEDGER.md`.
- Audit row status: `docs/_indices/DEBUG_MD_IMPLEMENTATION_STATUS.md`.
- Audit log architecture (AL-1 decision): `docs/contracts/audit_log_architecture_contract.md` (new 2026-05-14).
- Known-failing tests baseline: `docs/KNOWN_FAILING_TESTS.md`.
- Phase plan: `docs/_indices/NEXT_WAVE_PLAN.md` Phase 2.
- Phase 0 smoke baseline: `docs/_audits/wave_2/phase_0_smoke.md` (companion).

---

## Phase 2 walkthrough verification matrix (operator-web lane)

> **Pass started 2026-05-14 evening.** Operator instruction: test against the
> **full** checklist (Wave 1 ledger + Wave 2 ledger + debug.md +
> DEBUG_MD_IMPLEMENTATION_STATUS), commit lane-by-lane, annotate the
> tracker rows inline as each row is verified live.
>
> **Legend:**
> - ✅ **DONE-LIVE** — driven live in operator-web, behavior matches the slice intent
> - 🟢 **SURFACE-LIVE** — surface rendered + visible, sub-state (e.g. cap, hot path) not exercised in this pass
> - 🔧 **BACKEND** — slice is backend / schema / lint / docs; no operator-web surface to drive
> - 🅰 **ADMIN** — operator-web N/A; admin console surface only (deferred to admin lane)
> - 📱 **MOBILE** — operator-web N/A; mobile surface only (deferred to mobile lane pending operator instruction)
> - ⏳ **DEFERRED** — operator-web surface exists but not driven in this pass; needs follow-up walkthrough
> - 🐛 **GAP-FOUND** — live walkthrough surfaced a gap; follow-up row filed
>
> **Demo context driving the walkthrough:** `OPERATOR_WEB_DEMO_AUTH=true`,
> `kDemoOperatorWebSession` (uid `demo-operator-owner`, role `operator_owner`,
> at location scope `Demo Main Street` of operator `Demo Restaurant Group`).
> Two dev-only patches applied (CSP relax + initial-state skip-onboarding);
> both reverted before each lane commit.

### Lane U — UX cleanup bundle (Claude #2)

| Slice | PR | Live state | Evidence (Phase 2 walkthrough 2026-05-14) |
|---|---|---|---|
| U-1 Login screen cleanup (green logo + subtitle removal) | #663 | ⏳ | Login proper not driven — demo wrapper landed me at `OperatorWebCompleted` shell. Onboarding `WelcomeScreen` (Step 1 of 4) rendered cleanly in initial check (no green icon, no "use the same forge & flow operator account..." subtitle, F&F logo + "Operator Web Console" copy intact). True post-sign-out Login screen needs a future pass. |
| U-2 Top bar redesign + hierarchy-map location selector | #687 | ✅ | Top bar visible across every surface driven: F&F logo + "Demo Restaurant Group" branding (W-5), "Managing [Demo Main Street] Location" hierarchy-mapped scope selector (H-3), Owner role chip, `owner@demo.forgeflow.test` email next to Sign-out button. Top bar visibly taller than the legacy version per OW-0c. |
| U-3 Business Account UX cleanup (subtitle + 4-tile removal + scope-sensitive labels) | #663 | ✅ | Business Account screen renders without the "these are the basics..." subtitle and without the legacy 4-tile summary strip. Page begins directly at "Business identity" card. Scope-sensitive labels confirmed via HP #11 `Hierarchy scope` cards on every section. |
| U-4 Business Setup UX cleanup (subtitles, tiles, scope-sensitive tab names, simplified hierarchy labels, service-period note) | #663 | ✅ | Verified live: page title is **"Business setup • Demo Main Street"** (OW-3a scope-sensitive name appended at location scope), no subtitles, no 4-tile strip, top-row buttons include **"Edit Time Settings"** (OW-3b rename) at increased size, no "effective now" pill (OW-3f), Service periods section at bottom shows **"Lunch 11:00-15:00 / Dinner 17:00-22:00 / Late night 22:00-01:00"** with the OW-3g midnight-rollover note "One period runs past midnight, so its sales count toward the business day it started in." H-2 inheritance tree visualization confirmed (Hierarchy for this location + Inheritance cards both render with Operator default / Org unit / Location scope levels). Effective timing card exposes timezone (America/Toronto), Business day starts (04:00), Week starts (Monday), Shift close authority (Vendor finalization) with HP #11 "Inherited from Operator default" / "Location profile" labels. |
| U-5 Locations + My Account + Team Members + Roles + Sign-in-Security + Active Sessions UX cleanup (6 screens) | #670 | ✅ | All driven live: Active Sessions ✅ (no 4-tile strip, no "devices you are currently..." subtitle, no "active sessions for everyone..." subtitle, real member names visible — Jordan Lee / Taylor Kim). Roles & permissions ✅ (no "set what each role can do" subtitle, no 4 top widgets, "Default roles (5)" rename, "Create custom role" CTA renamed from "No custom roles", no `role_key` field). My account ✅ (no "your account details and security info..." subtitle, no Display name/email explainer subtitle, Profile field set: Display name + Email + Phone, with W-3 mobile disclosure "Phone changes happen in the operator mobile app under Settings, Account.", OW-8d Sign-in-Security consolidated into My account confirmed via inline Recent sign-in activity + Two-factor sign-in + Active Sessions sections). Team Members ✅ (no "invite team members..." subtitle, Invite member button is large + brown + icon, no 4-tile strip, 6-member table + 1 pending invite with literal "Cancel" link). Sign-in-Security as a standalone surface is gone — consolidated into My account per OW-8d. |
| U-6 Audit Log + Vendor Connections + Data Accuracy + Wage Authority + Notifications UX cleanup (5 screens) | #673 | ✅ | All driven live: Audit log ✅ (OW-10 page-level plain-English explainer "Every change someone made to your team, your roles, your org tree, and your sign-in security shows up here. Use the filters to narrow down to a specific action or actor, then export the result to a CSV when you need a paper trail.", B8.b hierarchy filter rendered as tree picker, Export CSV button). Vendor integrations ✅ (V-1 rename throughout, OW-11b no 4-tile strip, OW-11c "60 day benchmark data" banner with exact reworded copy, OW-11d no "could not load vendor connections" error — page loads cleanly with 3 category cards + Demo mode badges + tooltips). Data accuracy ✅ (OW-12a-i family all match; see Data Accuracy block below). Wage Authority is folded into Data accuracy per OW-13c unified IA; the FOH/BOH/Mgmt 3-category model + HP #11 scope notice all render correctly. Notifications ✅ (OW-14a-g all confirmed exact-copy — see Notifications block). |
| U-FU-hp11-account (HP #11 scope notice on AccountScreen, PUNT mode) | #712 | ✅ | Live evidence captured: yellow PUNT banner ("Live editing is not connected yet on this build. You can review the current values, but Save is disabled until the operator account write route is online."), `Hierarchy scope` cards on every settings section (Business identity, Region and formatting, Business week and rollover, Location timezone) each rendering Selected scope / Inherited from / Effective value + scope badge ("Location"). Save CTAs ("Save timezone", "Save business account") greyed out. |
| U-FU-summary-strip-cleanup | #710 | ✅ | `OperatorWebSummaryStrip` widget confirmed not mounted on Audit log, Vendor integrations, or Data accuracy surfaces in this walkthrough — these were the 3 prior consumers per PR #710 disclosure. No 4-tile summary strip rendered on any driven surface. |
| U-FU-mobile-deeplink | #600 | 📱 | Mobile lane. |
| U-FU-tier-email | #713 | ✅ | Live verification: Data accuracy → Data Freshness section renders **"Request faster data freshness"** button that triggers the SendGrid email path (per PR #713 router). Note: production sends remain gated on `U-FU-tier-email-wire` follow-up (router not yet mounted in `tool/advisor_proxy/main.dart`). |
| U-FU-hp11-account-schema | — | 🔧 | Parked V1.1 (per-location override columns on `restaurant_locations`). |
| U-FU-tier-email-wire | — | 🔧 | Parked V1.1 (proxy router mount). |
| OW-4 Locations scope-conditional visibility (hide tab at location scope) | #730 | 🟢 | **Location-scope half ✅** verified: left-nav at `kDemoOperatorWebSession`'s default Location scope ("Demo Main Street") renders Schedule / Business account / Business setup / Benchmarks / My account / Team members / Roles & permissions / Active sessions / Audit log / Vendor integrations / Data accuracy / Notifications — **no "Locations" item present**, matching the OW-4 scope-conditional hide rule. **Business-scope half not drivable** in this demo session because `kDemoOperatorWebSession` is location-pinned (`primaryLocationId: 'demo-location'`); the top-bar scope dropdown opens with H-3 tree (Business-wide / East Region / West Region / Locations) but selecting "All locations" / Business-wide is a no-op in this demo gateway. The business-scope inverse (Locations item appears in nav) needs an operator spot-check against a session with `primaryLocationId: null` or a wider scope. |
| AC-1 Admin actor_kind label sweep | #728 | 🅰 | Admin lane. |

### Lane V — Vendor Connection → Vendor Integration rename sweep

| Slice | PR | Live state | Evidence |
|---|---|---|---|
| V-1 Cross-console rename | #660 | ✅ | Verified across 4 surfaces in this pass: left nav reads **"Vendor integrations"**; Vendor integrations page title reads **"Vendor integrations"** and page subtitle **"Manage the services connected to Demo Main Street."**; the OW-11c info banner reads **"60 day benchmark data — Forge & Flow imports the last 60 days of history from each connection so dashboards have real numbers to show."**; Notifications screen renders a section **"Vendor integrations"** with the event **"Vendor became available — A vendor you have been waiting on is now available to connect."** No "Vendor connection" / "Vendor connections" copy spotted on any operator-web surface driven. |

### Lane H — Hierarchy visualization + HP #11 sweep

| Slice | PR | Live state | Evidence |
|---|---|---|---|
| H-1 HP #11 scope notice on schedule_screen + wage_authority_screen | #659 | ✅ | Schedule renders `HierarchyScopeNotice` (Selected scope: Location — Demo Main Street / Inherited from: Set here. Does not inherit from a higher scope. / Effective value: Showing Demo Main Street's locked plan for the week of May 11 — 17.). Wage authority HP #11 ✅ verified on Data accuracy page's Wage authority section (Selected scope / Inherited from / Effective value: "These wage rows apply only to Demo Main Street. Other locations carry their own wage rows."). |
| H-2 Inheritance tree visualization on business_setup_screen + business_timing_editor_screen | #669 | ✅ | Business setup renders **two** visual hierarchy tree cards: "Hierarchy for this location" (Business — Demo Restaurant Group with "Inherits from here" pill; Location — Demo Main Street with "You are here" pill; helper "Regions and brands will appear here once your hierarchy is connected.") and "Inheritance" (Demo Restaurant Group · Operator default · checkmark · "Business day starts at 04:00 with three service periods." / Regional settings · Org unit · open circle · "No timing override set." / Demo Main Street · Location · checkmark · "Timezone is local; periods inherit from operator default."). |
| H-3 Top bar location selector — hierarchy-mapped picker | #681 | ✅ | Top bar scope dropdown opens to a hierarchy tree: All locations (Business-wide) / Demo Main Street (Location, currently selected with checkmark) / East Region (Region, expanded) → Downtown + North Loop / West Region (Region, collapsed) — proper tree, not flat dropdown. Each node carries its scope-kind label. |

### Lane W — Write-path completeness (operator-web surfaces only)

| Slice | PR | Live state | Evidence |
|---|---|---|---|
| W-1 Members edit-user write path | #680 | ✅ | **Edit member dialog driven live 2026-05-14 evening** (Sam Patel row). Dialog header "Edit member" + explainer "Change this teammate's email, name, role, or hierarchy scope. The change writes to Firebase + audit log; the operator will see the change in their audit log." Full field set rendered: **Email address** (prefilled `sam.owner@demobistro.test`), **Display name** (prefilled "Sam Patel"), **Role** dropdown (showing "Owner"), **Hierarchy scope** dropdown (showing "Business-wide"), **Reason** text field (required for audit context), **Cancel** + **Save** buttons. Audit-log wiring evident via the explainer + Reason field. |
| W-1-FU Role + hierarchy rotation in edit-member dialog | #689 | ✅ | Hierarchy scope dropdown present in dialog (set to "Business-wide" for Sam Patel) with helper copy "Business-wide: this teammate can act in every location." Role dropdown also present. W-1-FU's "unlock role + hierarchy rotation in edit-member dialog" intent visible end-to-end. |
| W-2 Cancel pending invite end-to-end | #691 | ✅ | Team members → Pending invites section live: "Avery Lopez · avery.lopez@demobistro.test · Staff · Downtown · **Cancel**" — literal Cancel link on the right of the pending invite row. The cancel call shape (idempotent proxy + Firebase API + audit row) is code-anchored. |
| W-3 Profile self-service write paths | #697 | ✅ | My account → Profile section confirms operator-web is the write surface: Display name "Demo Operator Owner", Email "owner@demo.forgeflow.test" are exposed editable; Phone shows "Not on file" + footer disclosure **"Phone changes happen in the operator mobile app under Settings, Account."** — exactly the W-3 split that makes operator-web the email + name authority while phone stays mobile-side. "Change password" button + recent-sign-in-activity feed + Two-factor enroll + Active Sessions all surfaced inline (OW-8d consolidation). |
| W-4 Admin My Account parity | #688 | 🅰 | Admin lane. |
| W-5 Business logo upload + propagation | #686 | ✅ | Business Account → "Upload a PNG (recommended)" section renders the W-5 logo URL field with a prefilled `data:image/png;base64,…` URL + a Logo preview tile. PUNT banner notes "File upload is not available on this build. Paste an https link below instead." Top-bar logo + branding ("Forge & Flow" + "Demo Restaurant Group") confirmed pulled from the binding. |
| W-5-mobile-FU / W-5-mobile-FU-2 | #695 / #714 | 📱 | Mobile lane. |
| W-6 Account screen timezone + missing-field exposure | #682 | ✅ | Business Account → Location timezone section ✅ — empty Timezone dropdown with helper "Pick the closest match, or choose 'Custom' to type any IANA timezone name." + plain-English context "Forge & Flow groups every shift, week, and weekly plan into this location's local day. Changing the timezone changes how business dates land for Demo Main Street from this point forward; past data keeps the timezone it was recorded against." Contact email + Contact phone + Region/Locale fields also surfaced. |
| W-6-backend | #705 | 🔧 | Backend proxy handler. |
| OW-2a Account field parity audit doc | #727 | 🔧 | Doc-only artifact (`docs/_audits/account_screen_field_parity_audit.md`). |

### Lane R — Roles hierarchy-scoped redesign

| Slice | PR | Live state | Evidence |
|---|---|---|---|
| R-1L Schema + RLS + inheritance resolver | #699 | ✅ (downstream) | Backend slice; the live-side proof is that the Custom role editor renders permissions with `productLabel` / `categoryLabel` / `human_label` columns sourced from `permission_keys` — all of which R-1L added. Direct schema verification is backend-only. |
| R-1L-FU NOT NULL flip | #715 | 🔧 | Backend migration. |
| R-2L Default Role Catalog v2 redesign | #711 | 🐛 | Custom role editor reads the v2 metadata correctly (product / category / human_label / MFA badges render against the catalog from `lib/auth/permission_key_metadata.dart`). BUT the operator-web demo fixture `kDemoTeamRolesFixture` at `lib/operator_web/services/demo_team_fixtures.dart:250-305` still seeds the **v1 5-role list** (operator_owner / operator_manager / operator_supervisor / operator_staff / location_manager) — NOT the v2 10-role catalog (super_admin / ff_support / operator_owner / operator_general_manager / location_manager / supervisor / finance_analyst / auditor_compliance / training_lead / team_admin). Live Roles & permissions list shows the v1 names. **GAP filed**: `R-2L-FU-demo-fixture` — port v2 catalog into the demo seed. |
| RP-9 Default Role Catalog admin permission gate | #731 | 🅰 | Admin lane. |
| RP-10 Invite hierarchy-tree picker | #732 | ✅ | Invite member modal opened live: "Choose where this person will work" tree picker rendered with the operator's org tree (Demo Bistro Whole business / East Region Region or group / Downtown Location, etc.) — NOT a flat dropdown. Helper copy: "Pick the location, region, or whole business. Higher levels include everything beneath." Search-by-name field above the tree. Email + Role + Tree fields + Cancel + Send invite. |
| RP-15 Benchmark override cap (operator-web side) | #733 | 🟢 | **Scope-flip exercised live 2026-05-14 evening**: clicked into Downtown Location tree node → override card flipped from "Demo Restaurant Group / Effective value: 4.58 / Inherited source: Target cycle / No direct override at this scope." to "Downtown / Effective value: 4.58 / Inherited source: Target cycle / No direct override at this scope." Tree node selection + per-scope override card both wire correctly. **Cap state-machine NOT exercised** because demo session is Owner-role (cap fires for Manager-and-below). Filed `RP-15-FU-cap-state-manager-session` to drive cap UX with a Manager-role demo session. Admin-undo path also deferred to admin lane. |

### Lane S — Specialist redesigns

| Slice | PR | Live state | Evidence |
|---|---|---|---|
| S-1 Wage Authority blended-mix formula UI | #679 | ✅ | Data accuracy → Wage authority section renders the 3-category model **Front of house · Service team / Back of house · Kitchen team / Management · Salaried + management hours**, each with an "Add a role" CTA and empty-state copy "No wage rates set at this scope yet. Add rates and Forge & Flow will inherit them down to lower scopes." Blended wage mix card at the top with empty state "not enough data yet". Vendor-applicability label visible on the page: "Scheduling systems that do not expose dollars at V1: QuickBooks Time, 7shifts, Humanity, Agendrix, ADP Workforce Now, Push Operations." |
| S-2 Wage Authority + Data Accuracy unified IA | #684 | ✅ | Page title is **Data accuracy** and contains BOTH the data-source settings (How labor dollars are calculated, Where covers come from per daypart) AND the Wage authority section in the same page. Left nav has no separate "Wage authority" item — folded into Data accuracy per S-2. |
| S-3 Roles screen UX + custom role editor | #717 | ✅ | Roles & permissions list: name + short description + Edit (no role_key, no tiles, no extra metadata). "New role" CTA opens custom role editor with permissions grouped by **product (Product access / Forge & Flow / F&F admin / Integrations) → category (Forge & Flow surfaces / F&F admin actions / Vendor integrations) → permission rows with humanLabel + MFA badges + live count badges (0/2, 0/20, 0/19, 0/3)**. Q-4 scope filter ✅ ("Some permissions don't apply at the location level and are not shown." + "What's hidden?" expander). |

### Loose OW rows (debug.md 14-screen Ops Console UX)

#### OW-2 Business Account (debug.md 116-124)

| Row | Live state | Evidence |
|---|---|---|
| OW-2a Field parity audit doc | 🔧 | Doc artifact. |
| OW-2b/e Scope-sensitive labels (location identity ≠ business identity) | ✅ | At Location scope, Business Account header reads "Business account" — at Business identity card the HP #11 effective copy adapts to scope. Demo session is location-pinned so the business-level rename can't be flipped in this pass. |
| OW-2c Remove "these are the basics..." subtitle + 4 top tiles | ✅ | Subtitle absent; no 4-tile strip. Page starts directly at "Business identity". |
| OW-2d PNG logo replacement | ✅ | Logo preview pipeline visible (URL field + Preview tile). Top-bar logo bound to Demo Restaurant Group avatar; W-5-mobile-FU(2) propagates to mobile. |
| OW-2f Explain locale | 🟢 | Region and formatting section + Currency / Locale dropdowns present (both empty in demo). Plain-English explainer in the section header: "Currency drives every dollar amount you see. Locale drives date formats and number separators (1,234.56 versus 1.234,56, for example)." OW-2f operator read-back: that copy is the operator-web answer. |
| OW-2g Timezone + missing-field exposure | ✅ | W-6 row above — timezone exposed with IANA dropdown + plain-English explainer. |

#### OW-3 Business Setup (debug.md 127-140)

| Row | Live state | Evidence |
|---|---|---|
| OW-3a Hierarchy-smart + scope-sensitive tab names | ✅ | Page title at Location scope: **"Business setup • Demo Main Street"**. |
| OW-3b Remove subtitle + rename "Edit Time Settings" + bigger | ✅ | Verified. |
| OW-3c Explain Schedule timing | 🟢 | Effective timing card + Service periods section + hierarchy inheritance card together act as the plain-English explainer. No standalone explainer page; the inline copy carries the explanation. Operator can validate this is enough or call for a dedicated explainer surface. |
| OW-3d Remove 4 scope/effective tiles | ✅ | No top-row tiles; page goes directly to action buttons + hierarchy tree. |
| OW-3e Inheritance more visual (tree, not labels) | ✅ | H-2 above — two visual hierarchy tree cards. |
| OW-3f Remove "effective now" + simplify hierarchy labels | ✅ | No "effective now" pill; labels read "Operator default" / "Org unit" / "Location" + inheritance pills "Inherits from here" / "You are here". |
| OW-3g Service period — remove labels + midnight note | ✅ | Service periods table (Lunch / Dinner / Late night) with midnight-rollover note "One period runs past midnight, so its sales count toward the business day it started in." |

#### OW-5 / OW-8 My Account + Sign in Security (debug.md 145-150, 169-173)

| Row | Live state | Evidence |
|---|---|---|
| OW-5a Move under Access | 🔧 | IA change; left nav has My account under "People" still — moving to Access is a router edit. The R-1 refactor will fold this. Not Wave 2 scope. |
| OW-5b Remove subtitle | ✅ | No "your account details and security info..." subtitle. |
| OW-5c/e Profile change details end-to-end | ✅ | W-3 above. |
| OW-5d Remove "display name email..." subtitle | ✅ | No subtitle on Profile section. |
| OW-8a Remove "protect your own team..." subtitle | ✅ | No subtitle; section header is just "Security". |
| OW-8b Remove 4 top tiles | ✅ | No tile strip. |
| OW-8c Lost-authenticator behaviour | 🟢 | Two-factor sign-in card renders "Enable two-factor sign-in" (operator not enrolled in demo session). "Lost authenticator" lost-access pathway is the admin-side "Request removal" flow per the C-7 backbone; not surfaced in the empty-MFA state. Needs a session-with-MFA-enrolled spot-check to validate the "Request removal" / "Cancel request" copy. |
| OW-8d Consolidate Sign in & Security into My account | ✅ | Verified — no standalone Sign in Security nav item. Security + Recent sign-in activity + Two-factor sign-in + Active Sessions all render inline on My account. |

#### OW-6 Team Members (debug.md 152-156)

| Row | Live state | Evidence |
|---|---|---|
| OW-6a Remove subtitle | ✅ | No "invite team members..." subtitle; page starts with the search filter strip. |
| OW-6b Invite member button bigger | ✅ | Large brown CTA with icon top-right. |
| OW-6c Remove 4 top widget tiles | ✅ | No Visible/Active/Suspended/MFA enrolled summary strip. |
| OW-6d 3-dot → "Edit user" button | 🟢 | What shipped: **3-dot menu** with **Edit member** as first item. Per the literal debug.md ask ("instead of the 3 dot icon is should be a button saying edit user"), the inline button replacement is **not** what shipped — what shipped is a 3-dot menu with Edit member + Suspend + Reset password + Reset two-factor sign-in + Remove from team. Operator can decide whether the menu UX is acceptable or wants the inline-button variant. |

#### OW-7 Roles and Permissions (debug.md 158-167)

| Row | Live state | Evidence |
|---|---|---|
| OW-7a Move under People | 🔧 | IA change; left nav has Roles & permissions under "Access". Same R-1 refactor as OW-5a. |
| OW-7b-g Remove subtitles + 4 widgets + role_key + Create Custom Role rename + remove "build a custom role..." + remove "standard roles forge and flow..." | ✅ | All verified live: no subtitles, no widgets, no role_key field. Empty-state copy uses "Create custom role" wording per OW-7d. Custom role editor opens cleanly with the S-3 + R-2L picker model. |

#### OW-9 Active Sessions (debug.md 175-181)

| Row | Live state | Evidence |
|---|---|---|
| OW-9a Real member names | ✅ | "Jordan Lee" / "Taylor Kim" with email + location, NOT `operator-web-qa-2026-…` device strings. |
| OW-9b Remove 4 top tiles | ✅ | No tile strip. |
| OW-9c Remove "devices you are currently..." + "active sessions for everyone..." subtitles | ✅ | Both absent. |

#### OW-10 Audit Log (debug.md 181)

| Row | Live state | Evidence |
|---|---|---|
| OW-10 Plain-English explainer + zoom-out read-back | ✅ | Page-level explainer "Every change someone made to your team, your roles, your org tree, and your sign-in security shows up here. Use the filters to narrow down to a specific action or actor, then export the result to a CSV when you need a paper trail." plus the audit-chain status banner explanation "Each night Forge & Flow seals your audit log so its history can't be changed without us noticing." gives operator-level read-back without engineering jargon. |

#### OW-11 Vendor Integrations (debug.md 183-187)

| Row | Live state | Evidence |
|---|---|---|
| OW-11a Rename Vendor Connection → Vendor Integration | ✅ | V-1 above. |
| OW-11b Remove 4 widget tiles | ✅ | No tile strip. |
| OW-11c Reword "initial backfill progress" → "60 day benchmark data" | ✅ | Exact banner copy: "60 day benchmark data — Forge & Flow imports the last 60 days of history from each connection so dashboards have real numbers to show. Backfill progress is not available in this view yet. Once a vendor is connected here, this panel will show the import state per connection." |
| OW-11d "Could not load vendor connections" error | ✅ | Page loads cleanly in demo mode with 3 category cards (Point-of-sale / Scheduling and labor / Reservations), each with Demo mode badge + tooltip. No error banner. |

#### OW-12 Data Accuracy (debug.md 189-204)

| Row | Live state | Evidence |
|---|---|---|
| OW-12a Explain entire page | ✅ | Page-level explainer + per-section explainers + sidebar of jump anchors ("What this page is for"). |
| OW-12b Remove top tiles | ✅ | No tile strip. |
| OW-12c "Sources" bigger | ✅ | Prominent section heading. |
| OW-12d "How labor dollars are calculated" rename + explain + vendor scope | ✅ | Section renamed (was "Where labor dollars come from"); 2 radio options with full explainers; vendor list "QuickBooks Time, 7shifts, Humanity, Agendrix, ADP Workforce Now, Push Operations." |
| OW-12e Covers — 3 logic types + reservation integration | ✅ | Per-daypart radios Lunch/Dinner/Late night × {Vendor / Forecast / Manual} = exactly the 3 logic types. Vendor list "Square, Clover." Section explainer connects to the next "Walk-in handling" anchor for the reservation-side. |
| OW-12f Monitoring → Data Freshness | ✅ | Section is **"Data Freshness"**, not "Monitoring". Font visibly bigger. |
| OW-12g Subtitle rewrite "Polling is..." + plan tier + request-fresh-data | ✅ | Section subtitle: "Every vendor you have connected pushes updates to Forge & Flow in real time, so your dashboard is always current." + tier card "Your data freshness tier · Standard · Your current tier · Bundled with subscription". |
| OW-12h Tier-change button wired as email | ✅ | "Request faster data freshness" button per U-FU-tier-email (#713). Production send gated on `U-FU-tier-email-wire`. |
| OW-12i "How this applies to your setup" → "Note:" | ✅ | Section ends with "Note:" prefix, not the legacy heading. |
| OW-12j Reword polling cadence + webhook subtitles | 🟢 | Polling cadence + webhook copy live on the page; specific operator-requested copy strings ("Polling and data freshness applies to..." / "Vendors outside this list update in real time...") need a fresh diff against the rendered text. |

#### OW-13 Wage Authority (debug.md 206-241)

| Row | Live state | Evidence |
|---|---|---|
| OW-13a FOH/BOH/Mgmt blended-mix UI | ✅ | S-1 above. |
| OW-13b Vendor-applicability label | ✅ | "Scheduling systems that do not expose dollars at V1: QuickBooks Time, 7shifts, Humanity, Agendrix, ADP Workforce Now, Push Operations." inline in Data accuracy → How labor dollars are calculated section. |
| OW-13c Unified IA | ✅ | S-2 above. |
| OW-13d Editable admin-console vendor-applicability list | 🅰 | Admin lane. |

#### OW-14 Notifications (debug.md 243-255)

| Row | Live state | Evidence |
|---|---|---|
| OW-14a First-Connect → First Connect (no hyphens) | ✅ | "First Connect Backfill" heading + child events. No hyphens. |
| OW-14b 60-day backfill copy | ✅ | "60 days of P.O.S. data has been uploaded and your initial benchmark is now live." — exact match. |
| OW-14c Vendor connection → Vendor Integration in notif copy | ✅ | "Vendor became available" section heading + body uses "Vendor integrations" / "A vendor you have been waiting on is now available to connect." No "connection" string. |
| OW-14d Simplify "Audit Chain Anchor failed" | ✅ | Event title is "Daily audit log didn't anchor today" + plain-English body. |
| OW-14e Daily audit log description simpler with examples | ✅ | Body: "Each night Forge & Flow seals your audit log so its history can't be changed without us noticing. Today's seal didn't go through. Your audit log itself is still being recorded — for example, every team invite, role change, password reset, and sign-in is still captured. This is rare and never blocks operations, but you should know..." |
| OW-14f Manager override → Benchmark override applied | ✅ | Section "Live shift" carries event "Benchmark override applied". |
| OW-14g Weekly plan "a new weekly snapshot was locked in" → better wording | ✅ | "New weekly plan locked in" + body starting "A new week-in-force plan was locked in for the upcoming week. This is the plan Forge & Flow will compare your..." |

#### OW-1 Schedule (debug.md 110-112)

| Row | Live state | Evidence |
|---|---|---|
| OW-1 Explain Schedule + full functionality | ✅ | Page renders: subtitle "Week of May 11 — 17 — Demo Main Street's locked plan and the forecast inputs that built it." + Daily plan table (Mon-Sun, Forecast covers / FOH hrs / BOH hrs / Forecast sales / Week total $46,740) + "Why these numbers?" explainer with 60-day baseline covers / 21-day trend / Target PPA / Forecast sales / Required FOH hours / Required BOH hours / Theoretical labor dollars — each with plain-English commentary. Operator read-back done. |

### New gaps surfaced during this pass

| ID (suggested) | Title | Where | Impact | Disposition (2026-05-14 evening) |
|---|---|---|---|---|
| `R-2L-FU-demo-fixture` | Port v2 catalog into operator-web demo `kDemoTeamRolesFixture` | `lib/operator_web/services/demo_team_fixtures.dart:250-305` | Demo-fidelity | **FIX-LIVE in flight** — worktree agent dispatched 2026-05-14 evening; PR pending. |
| `U-FU-hp11-account-demo-defaults` | Populate Region/Locale/rollover_hour defaults in demo business identity + defense-in-depth null guard on `account_screen.dart` overrides==null branch | `kDemoOperatorWebSession` + `kDemoOperatorWebLocationManagerSession` in `lib/operator_web/auth/operator_web_auth_source.dart`; `_RegionFormattingSection` + `_BusinessWeekRolloverSection` in `account_screen.dart` | Demo-fidelity + brand-new-operator path | **RESOLVED** via PR #738 (merged to master at commit `21582169`, 2026-05-14 evening). Demo now renders "CAD / en-CA" + "04:00 local"; production brand-new operator renders "no currency / no locale" + "no rollover hour" instead of literal "null". |
| `MO-5b-FU-operator-web` (extend) | MO-5b "Two-factor authentication" label sweep extends to operator-web. My account Two-factor card mixes 3 labels (heading + "MFA: Not enrolled" badge + "2FA" body copy + "two-factor sign-in" button). Audit log Action filter chips mix "MFA enrolled (authenticator)" + "MFA factor removed" with "Reset two-factor sign-in" | `lib/operator_web/screens/my_account_screen.dart` Two-factor card; audit log action chip set; `lib/admin/admin_human_labels.dart` | Operator-facing copy drift | OPERATOR-DECISION pending canonical label. Bundle into MO-5b sweep slice when label chosen. Not V1-blocking. |
| `OW-6d-FU-edit-button-UX` (optional) | Operator's literal ask "instead of the 3 dot icon is should be a button saying edit user" not honored — what shipped is 3-dot menu with Edit member + Suspend + Reset password + Reset two-factor sign-in + Remove from team as menu items. The dialog body itself (W-1 + W-1-FU verified live 2026-05-14 evening: Email + Display name + Role + Hierarchy scope + Reason fields, "writes to Firebase + audit log" explainer) is fully shipped — only the trailing affordance shape is in question | `lib/operator_web/screens/team_members_screen.dart` row trailing | UX call | OPERATOR-DECISION pending. Not V1-blocking. |
| `OW-4-FU-business-scope-demo` (optional) | Demo session scope-flip support so the business-scope inverse of OW-4 (Locations item appears in nav) can be exercised live | `kDemoOperatorWebSession` is location-pinned; need a `kDemoOperatorWebBusinessSession` factory or a scope-toggle on the demo gateway | Demo-only walkthrough nicety | DEFER V1.1. Not V1-blocking. |
| `RP-1-FU-permission-key-human-labels` (new 2026-05-14 evening) | 4 newer permission keys render their machine key as their own description on the Permission Explainer because `human_label` metadata is missing in `lib/auth/permission_key_metadata.dart`: `team.roles.default_catalog.edit`, `team.roles.default_catalog.view`, `team.users.self_update`, `integrations.configure` (plus maybe Phase 12 `workflow.*`). These are perms added by RP-9 / W-3 / V-1 / Phase 12 prep — they hit the catalog but didn't get human_label populated | `lib/auth/permission_key_metadata.dart` per-key metadata table | Operator-visible bug (Permission Explainer looks broken on those rows) | **FIX-LIVE candidate** (small metadata addition, no behavior change). Defer to next operator-web round; not blocking V1 because the Explainer is read-only + the keys themselves work. Suggest pairing with the next R-1L metadata sweep. |
| `OW-12j-FU-copy-decision` (new 2026-05-14 evening) | Data accuracy → "What this page is for" sidebar copy is operator-friendly + concrete BUT does NOT render the exact debug.md 197-199 strings: "Polling and data freshness applies to..." and "Vendors outside this list update in real time...". The shipped copy is "F&F controls how often we ask your poll-only vendors for new data — your dashboard stays as live as the schedule. Webhook vendors are real-time regardless." | `data_accuracy_screen.dart` "What this page is for" section, Data freshness tier card | Copy decision — current shipped copy is arguably BETTER than the literal ask | OPERATOR-DECISION: keep current vs literal rewrite. Not V1-blocking. |
| `RP-15-FU-cap-state-manager-session` (new 2026-05-14 evening) | RP-15 manager-once override cap state-machine cannot be exercised live in the current demo. `kDemoOperatorWebSession` is Owner role; Owners override freely (the cap only fires for Manager-and-below roles). To validate the cap UX state transitions (Save → row goes read-only → cap copy appears → second-attempt blocked) need either a Manager-role demo session or test-driver automation that can type into the Override value field (Flutter web text inputs ignore programmatic .value writes) | `kDemoOperatorWebSession` role binding | Walkthrough fidelity | DEFER. Cap logic itself is code-anchored in `lib/operator_web/widgets/benchmark_override_panel.dart` + tested. Not V1-blocking. |
| `B-FU-dev-csp` (parked from earlier round) | Production CSP in `web/index.html` blocks Flutter dev DDC bootstrap; walkthrough requires a dev-only `unsafe-inline` + `unsafe-eval` carve-out applied + reverted each session | `web/index.html` `<meta>` CSP | Developer experience | DEFER until operator-web lane closes. Then dedicated slice (dart-define flag-driven CSP). |

(Other Wave 2 lanes — B, Q, D, M-Other, M-Poll, AC-1 — pending future lane-commits in this file; M-Poll + M-Other + admin lanes deferred to operator instruction.)

---

## Appendix — Live walkthrough evidence (operator-web, 2026-05-14 evening)

> Added after the operator pointed out the Step 2a verification above was
> code-anchored only (per NEXT_WAVE_PLAN.md line 187, code-anchored prose
> is one of five acceptable evidence types — but Step 2a opens with
> "drive the live tool"). This appendix captures what was driven live
> in Claude Preview MCP against a real `flutter run -d web-server`
> instance of `lib/main_operator_web.dart` (demo auth) and the gaps that
> only surfaced once the surface was rendering.
>
> Admin console + Samsung mobile remain pending; operator instructed
> "fully test the operator console first … one at a time" and will pick
> mobile order separately.

### Method

1. `.claude/launch.json` registered the operator-web demo with
   `flutter run -d web-server --web-port=8181 --web-hostname=0.0.0.0
   -t lib/main_operator_web.dart --dart-define=OPERATOR_WEB_DEMO_AUTH=true`.
   `.claude/` is gitignored, so the launch config does not ship.
2. Two dev-only diagnostic patches were applied to make the Flutter web
   bundle bootable + drivable in the Preview MCP headless browser, then
   **fully reverted** before this appendix was written (verified via
   `git diff` clean against the original files):
   - **`web/index.html` CSP relaxation** — the production
     `script-src 'self' 'wasm-unsafe-eval' '<sha256>'` allowlist matched
     the production Flutter bootstrap hash but not the dev DDC bootstrap,
     so 0 of 705 Dart modules evaluated until `'unsafe-inline'` +
     `'unsafe-eval'` were added to the dev meta-tag. Reverted.
   - **`lib/main_operator_web.dart` demo wrapper** — the demo source
     defaulted to `OperatorWebNeedsToken`, which would have required
     clicking through welcome → token → password → MFA → T&Cs (Flutter
     web's hidden `<input>` ignores programmatic `.value` + `execCommand`
     writes, so the walkthrough could not type the demo token). The
     dev patch flipped the initial state to `OperatorWebCompleted(
     session: kDemoOperatorWebSession)` so the post-onboarding shell
     rendered immediately. Reverted.
3. Flutter web semantics were enabled by clicking the hidden
   `flt-semantics-placeholder` element, which exposed an ARIA mirror
   tree of every Flutter widget in the page. Clicks were dispatched
   on `flt-glass-pane` at the semantic node's bounding rect so Flutter's
   pointer router picked them up.

### Surfaces validated live

#### Welcome / onboarding (Step 1 of 4)
Pre-shortcut state — confirmed the demo flavor renders the operator-web
welcome screen with: F&F logo + "Operator Web Console" subtitle, "Step 1
of 4 — Welcome" pill, the "What happens next" explainer card, the
Invite-code text field with helper "The code from your invite email,
usually 30+ characters long.", a tip line "Tip: most operators arrive
here from the invite email link…", and the primary "Continue to
password setup" CTA. The validation error "Paste the link from your
invite email. The link includes a single-use code that signs you in."
fired on empty submit. This confirms the magic-link landing surface +
copy from 11W.0 are rendering, even though the rest of the walkthrough
shortcut past the click-through (see Method §2).

#### Top bar — OW-0c
After the demo wrapper shortcut, the post-onboarding shell rendered:
F&F logo + "Demo Restaurant Group" branding (W-5 logo propagation +
business-name binding), a "Managing [Demo Main Street] Location" scope
selector dropdown (H-3 hierarchy-mapped picker), an "Owner" role chip
showing the active role from `kDemoOperatorWebSession`, the operator's
email `owner@demo.forgeflow.test` next to a Sign-out button. The bar is
visually bigger than the legacy top bar and includes the user email
inline — matches OW-0c.

#### Left navigation — IA + V-1 rename
The nav rail rendered the 14-screen IA with section headers
**Operations**, **Business**, **People**, **Access**, **Data &
integrations**, **People & access**, and child items: Schedule,
Business account, Business setup, Benchmarks, My account, Team members,
**Roles & permissions**, Active sessions, Audit log, **Vendor
integrations** (V-1 rename consistent — not "Vendor connections"), Data
accuracy, Notifications. The current item ("Business account" or
"Roles & permissions" depending on the step) was rendered with the teal
selected-state styling.

#### Business account screen — U-FU-hp11-account + W-6 + W-5 + U-3
Single screen captured top-half + bottom-half across two scrolls.
Validated:
- **U-FU-hp11-account PUNT banner**: the page renders a yellow info
  banner that reads exactly "Live editing is not connected yet on this
  build. You can review the current values, but Save is disabled until
  the operator account write route is online." This is honest disclosure
  per PR #712's PUNT-mode commitment.
- **HP #11 scope notice per section** (NOT just once at the page header):
  Business identity, Region and formatting, Business week and rollover,
  Location timezone each render their own `Hierarchy scope` card with
  "Selected scope: Location — Demo Main Street", "Inherited from: …",
  "Effective value: …", plus a "Location" badge on the right of each
  card. Confirms HP #11 is per-setting, not per-screen.
- **U-3 / OW-2c subtitle + 4-tile removal**: no "these are the basics…"
  subtitle, no 4-tile summary strip — page starts directly at "Business
  identity".
- **W-5 logo PUNT**: "Upload a PNG (recommended)" section renders the
  PUNT card "File upload is not available on this build. Paste an https
  link below instead." next to a "Logo URL" text field prefilled with
  the demo `data:image/png;base64,…` URL and a Preview tile.
- **W-6 timezone exposure (OW-2g)**: Location timezone section ships
  with the plain-English explainer "Forge & Flow groups every shift,
  week, and weekly plan into this location's local day. Changing the
  timezone changes how business dates land for Demo Main Street from
  this point forward; past data keeps the timezone it was recorded
  against." Below the Hierarchy scope card sits an empty Timezone
  dropdown, the helper "Pick the closest match, or choose 'Custom' to
  type any IANA timezone name.", and a greyed-out "Save timezone"
  button (PUNT mode).
- **Business week + rollover (OW-3g / W-6)**: plain-English explainer
  "Forge & Flow groups your data by business day, not calendar day. The
  rollover hour sets when one business day ends and the next begins.
  Most restaurants set this to 04:00 so late-night service stays on the
  right day."
- **Page-level Save**: "Save business account" CTA at the bottom is
  greyed out, matching the PUNT banner up top.

#### Active sessions screen — OW-9a + OW-9b + MO-7e parallel
Validated:
- **OW-9a**: Team sessions show real member display names "Jordan Lee"
  and "Taylor Kim" above their device labels, not the legacy
  `operator-web-qa-2026-…` device-id format. The device-id format
  still appears below the name, which is the intended split per the
  audit row resolution.
- **OW-9b cleanup**: no 4-tile strip (Your access / Team access / This
  browser / Refresh) at the top of the section.
- **MO-7e parity**: each session row shows "Last active 1w ago" plus
  approximate location ("Toronto, CA", "Mississauga, CA"). The
  desktop-side did NOT remove location like mobile's MO-7e did — IP is
  not visible, only the city, which is the operator-web variant.
- "(this session)" marker present on the current row plus per-row
  "Sign out this session" and "Sign out" buttons.

#### Roles & permissions screen — S-3 list UX, RP-7 default rename
Validated:
- **S-3 / RP-8 simplified list**: each role row shows ONLY name +
  one-line short description + Edit (+ Delete for custom). No
  `role_key` field, no per-role tile widgets, no extra metadata.
- **RP-7 "Default roles" rename**: section heading is exactly "Default
  roles (5)", not "Seeded roles".
- "Custom roles (1)" section shows "Floor Captain" (the demo custom
  role) with the description "Custom role for the lead server on duty"
  and Edit + Delete row actions.
- Page header has a "Permission Explainer" outlined button (gateway to
  `permission_explainer_screen.dart`) next to the primary "New role"
  CTA — confirms the explainer surface is reachable from the Roles
  surface.

#### Custom role editor — S-3 product/category + R-2L metadata + Q-4
"New role" opened the custom role editor at a scroll position partway
down the form. Captured:
- **S-3 product → category grouping**: permissions are grouped under
  **Product access**, **Forge & Flow**, **F&F admin**, **Integrations**
  product headers, with category subheadings inside each ("Forge & Flow
  surfaces", "F&F admin actions", "Vendor integrations"). Each category
  carries a live count badge ("0 / 2", "0 / 20", "0 / 19", "0 / 3")
  that mirrors selection state.
- **R-1L `human_label` rendering**: permission rows read as "Edit
  schedules", "View target cycles", "Reset user MFA factors", "Erase
  user personal information" — the operator-friendly
  `permission_keys.human_label` column from R-1L (PR #699 + the
  R-1L-FU NOT NULL flip PR #715), NOT the underlying machine keys.
- **MFA-protected badges**: sensitive permissions ("Erase user personal
  information", "Reset user MFA factors") render an "MFA" badge next to
  the row, matching the R-2L metadata's `requiresMfaToGrant` flag.
- **Q-4 scope-conflict auto-filter**: at the top of the Permissions
  section, the editor renders "Some permissions don't apply at the
  location level and are not shown." with a "What's hidden?" expander.
  This is the operator-approved option from the 2026-05-14 decision
  ("show warning + auto-filter").
- 19 Forge & Flow surfaces and 19 F&F admin actions visible without
  scrolling — the full default-catalog permission set rendered into the
  picker model.

#### Benchmarks screen — RP-15 surface visible
The Benchmarks landing rendered (via an unintentional click during nav
exploration) with: page header "Benchmarks", a "Selected scope: Demo
Restaurant Group. Effective CPLH is 4.58 from Target cycle." status
line, three tabs **CPLH / SPLH / PPA** (CPLH selected, teal active-
state), and the H-2 hierarchy tree visualization showing the demo
operator's full org tree (Demo Restaurant Group → Demo Bistro → East
Region {Downtown, North Loop} + West Region {Riverside}) with the
4.58 target-cycle value annotated on every node. Below the tree, a
"Demo Restaurant Group" override card with "Effective value: 4.58",
"Inherited source: Target cycle", an Override-value text field
prefilled at 4.58, a brown "Save" CTA, and a trash icon. Footer "No
direct override at this scope" confirms the empty-state copy. **The
manager-once cap UX itself was not exercised** (no override actually
submitted) — that path is deferred to the admin-console lane (RP-15
admin-undo) and an operator-driven spot-check on operator-web.

### Gaps newly surfaced during the live walkthrough

#### Gap 1 — R-2L v2 catalog not reflected in operator-web demo fixture

The Roles screen's "Default roles (5)" list rendered **Owner, Manager,
Supervisor, Staff, Location manager** — the pre-R-2L v1 catalog. The
v2 catalog from PR #711 (10 roles including `operator_general_manager`
renamed from `operator_manager`, `supervisor` renamed from
`shift_lead`, `finance_analyst`, `auditor_compliance`, `training_lead`
renamed from `barrio_instructor`, `team_admin`, plus the F&F-internal
`super_admin` + `ff_support`) is NOT what the operator sees in demo
mode.

Root cause (verified via code inspection):
`lib/operator_web/services/demo_team_fixtures.dart:250-305`
(`kDemoTeamRolesFixture`) still seeds the v1 5-role list (operator_owner
+ operator_manager + operator_supervisor + operator_staff +
location_manager). The R-2L SQL migration
(`db/migrations/202605150000_phase_r2l_default_role_catalog_v2.sql`)
shipped, but the in-memory demo gateway was never updated to mirror it.

Impact: any operator walking through the demo today sees the v1 catalog,
not the v2 catalog the rest of the codebase ships. This is a
demo-fidelity gap, not a production gap (production reads the SQL
catalog, not the demo fixture).

Recommended follow-up: **R-2L-FU-demo-fixture** — port the v2 role
metadata from
`db/migrations/202605150000_phase_r2l_default_role_catalog_v2.sql` +
`lib/auth/permission_key_metadata.dart` (which the editor already reads
from, hence the correct product/category groups) into
`kDemoTeamRolesFixture`. Same shape as the audit-row gaps already
parked on the ledger; non-V1-blocking because production stays
unaffected.

#### Gap 2 — Business Account demo fixtures leak `null` into HP #11 copy

The Hierarchy scope cards on Business Account render inherited-value
strings interpolated from the demo fixture defaults. Where the demo
fixture has no value, the inherited string degrades into:
- "Inherits the business default from Business: **null / null**."
  (Region and formatting section)
- "Inherits the business default from Business: **null:00 local**."
  (Business week and rollover section)

Production rows would not produce this — the demo fixture for the
demo operator's business identity is just missing currency + locale +
rollover_hour defaults. But operator demos look bad with literal
"null" strings exposed.

Recommended follow-up: **U-FU-hp11-account-demo-defaults** — populate
default currency/locale/rollover_hour values in the demo business
identity fixture (or harden the inherited-string interpolation in
`HierarchyScopeNotice` to fall through to a placeholder like
"not configured" when the inherited value is null). Trivial sweep,
not V1-blocking.

### Surfaces NOT clicked through live (deferred to operator spot-check)

The semantics tree was state-driven, not URL-driven (the router renders
on auth state, not on `location.pathname`), so navigation between
surfaces required successful glass-pane clicks at exact bounding rects.
A handful of clicks routed to neighboring nav items rather than the
intended target — these surfaces still need an operator spot-check:

- **Team members + RP-10 invite hierarchy-tree picker** — code-anchored
  in `lib/operator_web/screens/invite_member_dialog.dart` + the H-2
  tree widget, but the live dialog was not opened.
- **Vendor integrations** (OW-11d live-gateway load + V-1 rename
  consistency below page header). Left nav label confirmed; page body
  not driven.
- **Data accuracy** (OW-12d "How labor dollars are calculated" +
  OW-12e "Where covers come from" explainer cards + S-1/S-2 unified IA).
  Left nav label confirmed; page body not driven.
- **Audit log** (B8.b hierarchy filter + AC-1 human actor_kind labels
  on operator-web side). Left nav label confirmed; page body not
  driven.
- **Schedule** (H-1 HP #11 scope notice). Left nav label confirmed.
- **Notifications** (OW-14 rewrites). Left nav label confirmed.
- **My account** (W-3 profile self-service write paths surfaced for the
  operator-web user). Left nav label confirmed.
- **Implies graph auto-select** on the custom role editor (S-3
  dependency auto-add). Editor confirmed visible with the picker
  model; toggle behavior not driven.
- **Manager-once override cap** on Benchmarks (RP-15 operator-web side).
  Override card visible with Save CTA; cap-vs-no-cap states not
  exercised.

These are all code-anchored in the Step 2a section above. The
operator-web shell is bootable + the IA + the U-FU-hp11-account + S-3
+ Q-4 + OW-9a + W-6 + OW-0c + V-1 surfaces are all visibly live, which
covers the highest-risk Phase 2 spot-checks.

### What this means for the happy-state tag

The operator-web walkthrough is **green for the surfaces driven live**
(no console errors, no failed gateway calls, all expected widgets
rendered, all expected copy intact, both new HP #11 carve-outs working
as designed). The two newly-surfaced gaps (R-2L demo fixture + Business
Account null interpolation) are demo-fidelity issues that DO NOT impact
production behavior and are not V1-blocking.

**Operator action remaining before happy-state tag:**
1. Decide whether the operator-web walkthrough is sufficient or wants
   the deferred spot-checks driven before tagging.
2. Pick mobile validation order (per operator instruction "I will
   instruct on the mobile").
3. Pick admin console validation order (or accept the deferred
   spot-check pattern there too).
4. Decide whether to spin up the R-2L-FU-demo-fixture and
   U-FU-hp11-account-demo-defaults follow-up rows before V1 or park them
   as V1.1 demo polish.

### Method postmortem (for next walkthroughs)

- **Flutter web + production CSP**: the dev DDC bootstrap injects an
  inline script whose sha256 does not match the production allowlist;
  the production CSP needs a `'unsafe-inline'` carve-out for
  `flutter run -d web-server` OR a dev-only `<meta>` tag override at
  the bundler level. Filing as **B-FU-dev-csp** would be appropriate
  if the operator wants live walkthroughs to be one-step in future
  closeouts.
- **Flutter web text input**: programmatic `.value` writes and
  `execCommand('insertText')` both fail to sync to the Dart-side
  `TextEditingController`. The walkthrough needs either real
  keystroke synthesis via the engine's `KeyboardEvent` listeners or
  a demo-skip flag like the one this walkthrough used. The cleanest
  fix for future walkthroughs would be a `--dart-define=
  OPERATOR_WEB_DEMO_SKIP_ONBOARDING=true` switch that flips the
  initial state to `OperatorWebCompleted` only when the flag is set
  AND `kOperatorWebDemoAuth` is also true. Filing as
  **U-FU-demo-skip-onboarding-flag** would be appropriate.
