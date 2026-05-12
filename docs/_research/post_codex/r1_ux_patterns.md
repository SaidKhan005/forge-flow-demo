# Post-Codex Wave — UX Pattern Brief (R1)

Author: research agent
Date: 2026-05-12
Scope: NEW surfaces in the post-Codex wave + additive polish on top of what Codex
is shipping in `docs/_execution/admin_hierarchy_ux_cleanup/04_execution_slices.md`.
Out of scope (Codex is finalizing): shared scope-pane structure, scope-pane filter
bar layout, scoped-override column design for Data Accuracy and Polling, scope-aware
Data Accuracy / Polling structure, plain-English copy for System Health / AI Metrics.

Audience: implementation planners. Operators on the receiving end are restaurant
managers, not engineers; copy must read like training, not configuration.

---

## Executive Summary

This brief covers twelve UX surfaces split into three buckets:

1. Identity, access, and account safety — Role + permission editor (#1), Default
   role admin catalog (#2), Adaptive 2FA button (#5), My Account consolidation
   (#8), Mobile to Ops Web deep-link with fresh-MFA gating (#6).
2. Hierarchy and people — Inheritance tree visualization (#9), Hierarchy
   breadcrumbs (#10), Cancel pending invite (#11), Edit user inline (#12).
3. Operator-domain primitives — Blended wage mix table (#3), Demo to Live single
   switch (#4), Notifications mark-as-read + bell sync (#7).

Themes across all twelve:

- Reuse Codex's scope pane and breadcrumb. Do not invent a parallel hierarchy
  picker for any of these surfaces. The scope pane is THE hierarchy interaction
  in the admin shell.
- Default to "show inherited; expose advanced only on click". Restaurant
  managers do not need to see ltree paths, raw permission keys, or session
  fingerprints in primary scan.
- Every destructive or sensitive action carries (a) plain-English confirmation
  naming what will change, (b) one explicit undo window when feasible (24h
  grace for 2FA removal is the strongest precedent), and (c) clear actor
  identity in the resulting audit log row.
- "Default vs Custom" must be visually obvious without reading text. Pattern:
  small left-rail badge or pill, not a column. Custom items get an actions
  menu; defaults do not.
- Inline edit beats popups for low-risk field changes (name, email, role).
  Modals beat inline edits for cross-row consequences (hierarchy reassignment,
  permission cascades, anything that fires a cascade preview).
- For each cross-device state surface (notifications, sessions, demo state, 2FA
  factors), pessimistically assume the user has two tabs and a phone open at
  once. Slack's "explicit desktop and mobile values, no sync magic" lesson
  applies.
- Operator-friendliness test: if a restaurant manager scanning the screen on a
  phone in the back office cannot identify (a) what scope they are editing, (b)
  what will change, and (c) how to undo it, the surface fails.

The rest of this document gives, per item: real product references with links,
the pattern principles to copy, the failure modes to avoid, and how it lands
for the restaurant-manager audience.

---

## 1. Role + Permission Editor with Dependency Cascade

Goal: operator (or F&F admin in the global catalog) builds or edits a role.
Selecting a child permission auto-includes its dependencies and parent product.
Display permissions inside a product taxonomy. Distinguish Default vs Custom
roles. Warn on orphan permissions and location-scope mismatches.

**References.**

- Stripe Dashboard team roles. Permissions grouped by product (Payments, Billing, Connect, Identity, Issuing, etc.) with Read / Write / None tri-state per resource. Write implies Read. Custom roles created under Settings > Team > Roles. [blog](https://stripe.com/blog/new-roles-and-permissions-in-the-dashboard) [docs](https://docs.stripe.com/get-started/account/teams/roles)
- Stripe restricted API keys reuse the same taxonomy for key scoping — "permissions live inside a product tree, not a flat list". [docs](https://docs.stripe.com/keys/restricted-api-keys)
- Salesforce permission sets auto-enable a required parent permission in the profile UI and surface a message naming the dependency; custom permissions support explicit parent-required declarations. [Ben](https://www.salesforceben.com/custom-permissions-in-salesforce-fine-tuning-user-access/)
- GitHub custom org / repo roles. Two tabs (Organization, Repository) inside "Add permissions"; base role dropdown picks a "starts from" preset, additional permissions layer on top. Roles view shows direct vs team-derived assignments. [docs](https://docs.github.com/en/enterprise-cloud@latest/organizations/managing-peoples-access-to-your-organization-with-roles/about-custom-organization-roles) [changelog](https://github.blog/changelog/2024-08-29-add-repository-permissions-to-custom-organization-roles/)
- Microsoft 365 admin center custom roles. Permissions grouped by function (User management, Billing, Compliance); page auto-disables permissions the current admin does not hold ("you cannot grant what you do not have"). [docs](https://learn.microsoft.com/en-us/microsoft-365/admin/add-users/about-admin-roles)
- Auth0 role permissions tab — typeahead add-one-at-a-time is not great UX, but the API model is the conceptual anchor. [docs](https://auth0.com/docs/manage-users/access-control/configure-core-rbac/manage-permissions)

**Principles.**

1. Two-pane layout. Left pane: product taxonomy tree (collapsible). Right pane:
   permissions inside the selected product, rendered as a grouped list with
   tri-state (None / Read / Write) or checkboxes if binary. Stripe uses this;
   GitHub uses a flatter variant. For F&F, the taxonomy is your existing
   permission key catalog (`lib/auth/`) reorganized into operator-meaningful
   product groups: People, Hierarchy, Data accuracy, Polling, Integrations,
   Security, Support, AI, etc.
2. Cascade preview on click, commit on save. When the user checks a child
   permission, immediately show a small diff strip near the save button:
   "Selecting `wage.edit` will also enable `wage.read` (required) and
   `data_accuracy.view` (parent product). Both will be added on save." This is
   the failure mode Salesforce ducked by silently auto-enabling — operators
   resent the magic. Make the cascade visible before commit.
3. Default role distinction. Default roles are read-only with a pill labeled
   "Default" or "Built-in" and no actions menu. The Edit affordance opens a
   "Duplicate to customize" CTA instead. Linear, Stripe, and Microsoft all use
   this guardrail. https://linear.app/docs/members-roles
4. Custom role badge. Right of the role name, a subtle "Custom" pill plus an
   actions menu (Edit, Duplicate, Delete, View users). Stripe and GitHub both
   show counts ("3 members") inline; do the same.
5. Orphan permission warning. If the role references a permission key that no
   longer exists in the current catalog (deprecated, removed by F&F), render
   the row with a yellow chip "Removed by F&F" and a Resolve link that
   offers Drop or Replace-with. WordPress User Role Editor and Drupal both
   built this in response to a recurring "ghost permission" support burden.
   https://www.drupal.org/project/drupal/issues/3358586
6. Location-scope warning. Some permissions only make sense at location scope
   (vendor connection write, polling tier edit). If the role is assigned at
   business scope but contains location-only permissions, show an inline
   advisory at the top of the editor: "This role contains 3 permissions that
   take effect only at location scope. They will be silently ignored above
   that scope." Use the same advisory language Codex's scope pane will use.
7. Product-taxonomy display. Group permissions by 1-2 levels max
   (Product > Resource). Three-level trees lose people. Use the exact
   product names operators see elsewhere in nav so they don't have to
   translate ("People" not "user_management").
8. Raw permission keys live in a tooltip or a "Show details" toggle on each
   row, never in primary scan. Confirmed by Codex Slice 6 work.

**Avoid.**

- Silent dependency auto-include with no diff. Salesforce's profile UI got
  trust complaints exactly here. Always preview.
- Flat permission list with no grouping. Restaurant managers will not survive
  120 checkboxes on one screen.
- Rendering raw keys (`shifts.write`, `wage.edit`) as the primary label. Codex
  is already fixing this for the members screen; the role editor must follow
  the same rule.
- Allowing edits to Default roles. Hard guardrail: Default = read-only +
  duplicate. The doctrine doc lists Default role catalog editing as F&F admin
  only; this is the right line.
- Mixing F&F-global product additions (a new vendor product) into operator
  custom-role editing without a "new since last edit" indicator. Roles drift.
  Highlight new permissions added by F&F since the role was last touched, with
  a "Review changes" button.

**Operator fit.**

Restaurant managers will live almost entirely in Default roles. The custom-role
editor is a power user surface (multi-location operators, F&F admins). For the
common case ("which permissions does Manager have?"), the screen must work as a
read-only inspection view first; editing is opt-in.

---

## 2. Default Role Admin Catalog (F&F Admins Only)

Goal: per locked decision #2, F&F admins adjust the Default role permission set
globally across every business. Operators inherit the change.

**References.**

- Microsoft Entra ID / 365 admin "built-in roles" catalog: table with name, description, assigned count, type; row opens a side panel with permissions; some built-ins editable in preview. [docs](https://learn.microsoft.com/en-us/microsoft-365/admin/add-users/about-admin-roles)
- Salesforce profile catalog. Standard profiles (System Admin, Standard User, Read Only) in a system catalog separate from custom, with a permanent "Standard" badge.
- Auth0 Management Dashboard > Roles is tenant-global; destructive actions carry "this affects every application in this tenant" copy at the top.
- Linear team-owners (2025-12) adds a system-level Owner role at workspace scope, surfaced as a non-deletable row. [changelog](https://linear.app/changelog/2025-12-17-team-owners)

**Principles.**

1. Visually separate "F&F-admin surface" from operator surfaces. Different top
   header banner ("F&F Admin: Default Role Catalog") and ideally a slightly
   different chrome color. Multi-tenant SaaS that share UI between
   tenant-admin and product-admin (Auth0, Stripe Connect) consistently use a
   color-coded banner to prevent disastrous misclicks.
2. Show blast radius before every save. "Saving will affect 47 businesses,
   312 locations, 1,403 active users." This is the unique F&F-admin
   requirement vs operator role editing. Modal confirmation must restate the
   count and the diff in plain English. Stripe's API key revocation modal is
   a decent pattern: lists affected resources, requires typing role name to
   confirm for high-blast-radius changes.
3. Version/changelog inline. Each Default role shows "last changed by [admin],
   [date], affecting X businesses". Tap to see the diff. Auth0 and GitHub
   both expose Tenant audit logs adjacent to the role editor.
4. Operator visibility. Operators must see "Updated by F&F on [date]" on each
   Default role in their own role list, with a "what changed" link. This is
   the operator-side outcome of #3 and is the part most products skip.
5. Deprecation flow. When F&F admins remove a Default permission, the catalog
   must offer "Mark deprecated (read-only, hidden in new role pickers, kept
   for existing assignments) vs Hard remove (every assignment drops the
   permission)". Default to deprecated-first. Slack and Salesforce both
   learned this the hard way.

**Avoid.**

- Using the same screen as operator role editing with a hidden "you are
  F&F admin" toggle. Misclicks are catastrophic.
- Pushing changes without a blast-radius preview.
- Letting F&F admins delete a Default role that still has operator
  assignments. Always require migration to another role first.
- Not surfacing the change downstream. Operators need to know their Manager
  role just got a new permission.

**Operator fit.**

Operators never see this screen. They DO see the resulting "Updated by F&F"
indicator on Default roles, and they need a one-line plain-English summary
("Now allows editing weekly forecast") rather than a permission key diff.

---

## 3. Blended Wage Mix Table

Goal: operator types in category x headcount x hourly rate. The row computes a
subtotal. The table auto-rolls a blended average across rows. Mobile is
view-only.

**References.**

- 7shifts labor cost calculator — web grid (role, count, hours, rate, computed weekly cost) with a live blended summary. [calc](https://www.7shifts.com/labor-cost-calculator/) [wages](https://kb.7shifts.com/hc/en-us/articles/4417513897491-Hourly-Wages-and-Salaries-Overview)
- Toast Payroll multi-rate — multi-rate per employee, hours tracked per rate, blended OT applied. [docs](https://support.toasttab.com/en/article/Toast-Payroll-View-Your-Paystubs)
- Harvest timesheets grid is the canonical editable-spreadsheet + live-total pattern. See Theresa Neil's table UX guide. [link](http://designingwebinterfaces.com/ultimate-guide-to-table-ui-patterns)
- PatternFly inline edit + summary row. [link](https://www.patternfly.org/components/inline-edit/design-guidelines/)
- DataTables Editor KeyTable for Excel-like keyboard nav (Tab cell, Enter commit, Shift+Tab back). [link](https://editor.datatables.net/examples/inline-editing/simple)

**Principles.**

1. Always-editable cells (no pencil per row needed for this many fields).
   The whole table is a spreadsheet; the operator expects to type-tab-type-tab.
   Pencil per row is right when most rows are read-only with one editable
   field; here, three of five columns are editable.
2. Live subtotal column updates on blur, never on each keystroke. Operators
   pasting in rates will fat-finger; debounce calc.
3. Blended average pinned in a footer row, styled distinctly (slightly heavier
   weight, subtle background). Show both blended hourly and total monthly
   cost so the calculator output is immediately useful.
4. Inline validation in the cell. Non-numeric rate -> red border on blur with
   a tooltip; do not steal focus. Negative or absurd values (>$200/hr) get a
   warning chip, not a hard block, since legitimate edge cases exist.
5. Add row at the bottom is a plus button + tab-from-last-cell shortcut.
   Restaurant operators with bookkeeping experience expect Excel ergonomics.
6. Mobile view-only variant. Stack each row as a card: category big, headcount
   x rate as a small line, subtotal right-aligned. Footer card pins blended
   average. No edit affordance on mobile to avoid keyboard-driven errors on
   small screens. Tell the user "Edit on desktop" inline if they tap a value.
7. Save behavior. Either (a) save-on-blur per row, with a tiny "Saved" chip
   that fades, or (b) bottom-of-screen "Unsaved changes — Save" sticky bar.
   Pick (b) if the calc is part of a larger form; (a) if it's a standalone
   surface. Either way, never silently auto-save without an indicator —
   blended-wage edits ripple into labor cost projections elsewhere.
8. Source of the headcount column. If headcount is derived from another
   surface (people table), label the column as "Headcount (from team
   roster)" with a tooltip linking to it; do not let operators edit it here
   if it is denormalized.

**Avoid.**

- Recalculating blended average on every keystroke (jitter; bad on mobile).
- Forcing operators to click a Save per row. Spreadsheet ergonomics demand
  bulk commit.
- Allowing the rate column to silently accept "$15/hr" (currency symbol +
  unit) when the field is numeric. Either parse aggressively or constrain to
  numeric-only with a fixed-prefix.
- Hiding the blended math. Operators must see the formula in plain English
  (small "How this is calculated" link near the footer): "Blended hourly =
  sum(headcount x hourly rate) / sum(headcount)".
- Letting mobile users tap into an edit state that requires zooming and
  hunting. View-only on mobile is the right call.

**Operator fit.**

Restaurant managers love spreadsheet ergonomics on desktop and hate them on
phone. This is the right surface to make explicitly device-aware. Lead the
screen with a one-liner: "This is your wage mix today. Update it when you
hire, lose, or change rates."

---

## 4. Demo to Live Single Switch (Mobile)

Goal: per locked decision #6, one toggle flips demo -> live underneath at the
per-(operator, location, category) grain. Need a way to surface partial state
when some categories are live and others are still demo.

**References.**

- Stripe Test/Live toggle — single switch in top nav, persistent per-user, banner when in test. [docs](https://docs.stripe.com/testing-use-cases)
- TalentLMS Demo mode — sidebar toggle into sandbox + pinned banner; canonical "always-visible state". [help](https://help.talentlms.com/hc/en-us/articles/20569181181724-How-to-use-the-TalentLMS-Demo-mode-sandbox-to-test-drive-the-platform)
- Slack notification refactor 2024 — "explicit desktop and mobile values, no sync magic". Directly relevant to mixed per-category state. [eng](https://slack.engineering/how-slack-rebuilt-notifications/)
- W3C ARIA mixed-state checkbox — standard primitive for partial state across children. [link](https://www.w3.org/WAI/ARIA/apg/patterns/checkbox/examples/checkbox-mixed/)

**Principles.**

1. Single switch with three observable states: All demo, Mixed (some demo,
   some live), All live. The mixed state is the special trick for F&F because
   per the contract a vendor connection at one category flips just that
   category. Use an indeterminate / segmented visual (e.g., a switch that is
   half-filled, or a switch with a tiny "3 of 5 live" annotation right of it).
2. Tap to expand. The mixed switch is not directly tappable to "force all
   live" — tapping it expands to show per-category state: POS Live, Labor
   Demo, Reservations Demo. From there the operator sees which categories
   moved naturally (via vendor connection) and which are still demo. This
   prevents the user from accidentally flipping every category at once.
3. Persistent global banner when any category is in demo. Stripe-style: top
   strip "Some data is demo — POS is live, Labor and Reservations are demo".
   Never hide the demo state; HP #2 says demo persists post-launch, so the
   banner must be permanent until full conversion.
4. Per-category flip from this view is one-way through "connect a vendor",
   not a toggle. Surface the connect CTA inline for each demo category.
   Per the contract, disconnect does not auto-revert; the toggle is for
   observation, not direct control.
5. Match the contract's actual state model. The toggle is read-out of
   `demo_mode_state`, not a writer. Make this clear in the help text: "This
   reflects what your data shows today. To move a category to live, connect
   the vendor that owns it."
6. Mobile-first sizing. The switch + banner combination is roughly the upper
   third of the home screen on phone; if the user has anything in demo, the
   first thing they see is what's live and what isn't.

**Avoid.**

- Treating the toggle as a write affordance when the model is read-only with
  vendor-connection writers. This is the bug Slack avoided with their
  preference refactor: do not let the UI imply a mutation it cannot make.
- Hiding the demo banner once any category is live. Partial-live is the
  steady state for most operators for weeks during rollout.
- Showing one number ("4 of 5 live") without naming what's still demo. The
  named-category breakdown is the whole point.
- Per-category flip on tap. Confirm-on-tap is fine for "force all to demo"
  in dev tooling, but in production the only path to Live is via vendor
  connection.

**Operator fit.**

Restaurant managers will see this on their phone. Plain English wins: "Some of
your data is still sample data. Connect [vendor] to start using your real
numbers." Avoid "demo state", "production mode", "sandbox".

---

## 5. Adaptive 2FA Button — Four States

Goal: one button in My Account / Security that shows correctly for: not
enrolled, enrolled, removal requested (24h grace), removable.

**References.**

- GitHub 2FA — single Security panel with explicit per-factor state; removal goes through step-up (sudo mode) + confirmation. [docs](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/sudo-mode)
- Shopify two-step auth — status panel listing each method (authenticator, SMS, security key, biometric), each row has Remove or Setup. [help](https://help.shopify.com/en/manual/your-account/logging-in/two-step-authentication/security-key)
- Auth0 MFA factors — API distinguishes active vs pending; pending are hidden from operator UI. [docs](https://dev.auth0.com/docs/secure/multi-factor-authentication/manage-mfa-auth0-apis/manage-authenticator-factors-mfa-api)
- Salesforce MFA grace period — built-in countdown with extendable bar; the strongest precedent for the 24h-removal-requested state. [help](https://help.salesforce.com/s/articleView?id=sf.mfa_registration_grace_period)
- Smashing Magazine + LogRocket on 2FA UX. [smashing](https://www.smashingmagazine.com/2022/08/authentication-ux-design-guidelines/) [logrocket](https://blog.logrocket.com/ux-design/creating-painless-2fa-user-flow/)

**Principles.**

1. Four visually distinct states for the same button slot:
   - Not enrolled: CTA primary "Turn on 2FA"; subtitle "Protect your account".
   - Enrolled: status row with green check, "Two-step verification is on",
     factor list below. Primary action becomes "Manage methods", destructive
     "Turn off" is tertiary and lives in an actions menu.
   - Removal requested (24h grace): warning row with a countdown,
     "Two-step verification turns off in 23h 14m. Cancel". Primary action is
     Cancel. Destructive removal is hidden until grace expires. This is the
     pattern Salesforce uses and is the strongest precedent for a
     time-windowed undo. Add a small "Why the wait?" tooltip explaining the
     24h cooldown prevents a single-credential takeover from disabling 2FA
     instantly.
   - Removable (grace expired): destructive button "Turn off two-step
     verification". On tap, modal confirmation with re-auth (step-up).
2. State machine over status string. Each state has one button label, one
   icon, one color. Do not stack two buttons (Cancel + Turn off) in the
   grace state — it invites misclicks.
3. Step-up required on Request-removal AND on Cancel. Cancellation is itself
   a security event; assume an attacker could be in a session.
4. Cross-device sync. The grace countdown must be authoritative server-side
   and reflected on every device. Avoid client-side timers that drift. The
   Slack notification rebuild lesson applies: explicit server state.
5. Plain-English reason on grace. "We wait 24 hours before turning off 2FA so
   that if someone got into your account, you have time to stop them."
   Operators understand this if you say it; they will not understand "cooldown
   window" or "grace period".

**Avoid.**

- Removal that takes effect instantly with no countdown.
- Letting the user start a new removal-request during the grace period
  (state confusion). One request at a time.
- Showing the grace countdown without a Cancel that is more prominent than
  any destructive option.
- Using the same button color for all four states.

**Operator fit.**

Restaurant managers will encounter this maybe twice a year (enrollment, phone
change). The screen must be self-explanatory the second time even though it
looked different the first time. Same button slot, different state — Stripe
and GitHub both anchor to "one row per security factor, each with its own
state and actions".

---

## 6. Mobile -> Ops Web Deep-Link Handoff with Fresh-MFA Gating

Goal: per locked decision #5, JWT is reused across mobile and Ops Web. When the
operator taps a deep link from mobile that lands on a sensitive Ops Web
surface, confirm the handoff and require fresh MFA for sensitive landings.

**References.**

- Shopify App Bridge session tokens — JWT session reuse between embedded app and Admin shell; embedded surface verifies signature and rebuilds session. [docs](https://shopify.dev/docs/apps/build/authentication-authorization/session-tokens/set-up-session-tokens)
- GitHub sudo mode — 2h re-auth window, every sensitive action resets it; full-screen prompt then auto-returns to the original action. [docs](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/sudo-mode)
- Auth0 step-up for sensitive endpoints — ID-token claims encode MFA freshness; deny entry until challenged. [docs](https://auth0.com/docs/secure/multi-factor-authentication/step-up-authentication)
- One-time-code deep-link redemption — link carries single-use code, app redeems server-side, code consumed. [Curity](https://curity.io/resources/learn/sso-for-mobile-apps-with-openid-connect/)

**Principles.**

1. Handoff confirmation page on the web side. When the deep link opens a new
   browser tab, the landing surface is not the target screen but a one-step
   "Continue as [user@email] -> [Target screen name]". This protects against
   misrouted links and gives the operator a chance to recognize the device
   they are now on. Stripe and Slack both do this when opening from an SMS or
   email link. Skip it only for benign landings (read-only views).
2. Fresh-MFA gate on sensitive landings. If the deep link targets a sensitive
   surface (role editor, default-role catalog, hierarchy delete, sign-in
   security, demo flip, billing), require step-up before the screen renders.
   Mirror GitHub sudo: the gate is a full-screen prompt that, on success,
   returns to the original deep link path.
3. Single-use code in the URL, not a long-lived JWT. The mobile app mints
   a short-lived (60-120 s) one-time code that the web side redeems for a
   fresh session bound to the operator's existing identity. This is the
   industry pattern and avoids leaking refresh tokens via link forwarding.
4. Same operator only. The handoff must verify that the web side is either
   not signed in or signed in as the same operator. If signed in as a
   different operator, show a "Switch account?" interstitial — never silently
   merge sessions.
5. Audit every handoff. Per the proxy conventions, handoff redemption emits
   an audit row (actor, source device, target route, fresh-MFA result).

**Avoid.**

- Putting the access token directly into the deep-link query. Sharing the
  URL = full account takeover.
- Skipping the confirmation interstitial. Operators on shared devices
  (back-office PC) need the recognize-or-deny moment.
- Reusing a stale MFA assertion. If the mobile app's last MFA challenge was
  3 days ago, fresh-MFA on the web side should re-prompt.
- Returning to "home" after step-up instead of the deep-link target. This is
  the single biggest sudo-flow regression for users; preserve the intent.

**Operator fit.**

The flow is almost always invisible (token redemption, no extra step), and that
is the goal. The only time the operator notices it is on sensitive landings,
where the fresh-MFA prompt should explain what they are about to do in one
line: "You're about to change role permissions. Confirm with your authenticator
to continue."

---

## 7. Notifications Mark-as-Read + Bell-Badge Sync

Goal: notifications mark as read consistently across mobile + web; the bell
badge invalidates correctly across devices.

**References.**

- Slack notifications rebuild (2024) — case study on cross-device sync; migrated four conflicting preference paradigms to one explicit (desktop, mobile) tuple. [eng](https://slack.engineering/how-slack-rebuilt-notifications/)
- PatternFly notification badge — mark-all-as-read, unread-only filter, badge-clear semantics. [link](https://www.patternfly.org/components/notification-badge/design-guidelines/)
- monday.com bell — "mark all as read" in header + per-row read/unread toggle. [link](https://support.monday.com/hc/en-us/articles/360015535060-Bell-Notifications)
- Linear inbox + GitHub notifications — "viewing the panel marks visible items seen, explicit click marks read" (seen-vs-read distinction).
- Courier notification center guide. [link](https://www.courier.com/guides/how-to-build-a-notification-center/chapter-3-best-practices-for-notification-centers)

**Principles.**

1. Server-authoritative read state. Mark-as-read is a server mutation; client
   optimistically updates, then reconciles on socket push. Badge count is
   derived from server count, not local cache. Slack's lesson: phantom
   badges always come from client-side caches drifting from server truth.
2. Distinguish "seen" from "read". Opening the panel can set "seen" (badge
   clears, list still shows unread styling) and a per-item click sets
   "read". This is Linear's model and works well when the inbox is busy. If
   the F&F bell is always small (a handful of notifications), collapse to
   "open = mark all read" with an explicit Undo toast for 5 seconds.
3. Mark-all-as-read as a single top-of-panel action. PatternFly, monday.com,
   GitHub all do it. Include a confirmation only if the unread count is
   large (>20).
4. Per-row read toggle. Restore unread on accidental clicks. Add a "mark
   unread" item in the row's overflow menu.
5. Bell badge contract. Badge shows unread count up to 99+. Badge color is
   the only severity signal (red for critical, neutral for informational);
   do not use color to encode count.
6. Per-device delivery vs read-state. Read state syncs across devices; push
   delivery may suppress on already-active devices. This is the Slack
   "only when away from desktop" pattern and is the right default for F&F
   so a notification doesn't buzz the manager's phone while they're working
   at the back-office PC.
7. Stale badge recovery. When the client reconnects after offline, refetch
   counts from the server immediately. Slack and PatternFly both call this
   out as a common bug class.

**Avoid.**

- Local-only mark-as-read that does not propagate.
- Badge that pulses on the manager's phone while they actively triage on web.
- Mark-all-as-read that cannot be undone for misclicks.
- Treating delivery and read as the same state.

**Operator fit.**

The bell is glanceable. The whole UX is "does this badge mean something I need
to look at right now?" Anything that erodes that trust (phantom counts,
duplicate alerts) will make managers ignore the bell entirely.

---

## 8. My Account: Sign-in Security + Profile + MFA + Active Sessions

Goal: per locked decision #7, one place for the operator's own account that
covers profile, sign-in security, MFA enrollment, and active sessions.

**References.**

- Google Account Security — subsections: How you sign in, Recent security activity, Your devices, Connected apps; each is a card with one primary action. [help](https://support.google.com/accounts/answer/185839)
- GitHub Settings — left-rail nav (Profile, Account, Notifications, Billing, Security, Sessions, SSH/GPG keys). Sessions page is a clean precedent. [docs](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/viewing-and-managing-your-sessions)
- Shopify Account > Security — Devices section with per-row Log out + "Log out everywhere" above five. [help](https://help.shopify.com/en/manual/your-account/logging-in)
- Stripe team profile / 2FA / API key panels — one primary action per card, never two destructive visible at once.

**Principles.**

1. Left-rail navigation inside the My Account surface, not horizontal tabs.
   Profile, Security, MFA, Active sessions, Notifications, Sign out. The
   operator should be able to deep-link to a sub-section.
2. Profile card first. Name, email, phone, photo (optional). Inline edit per
   field (see #12 pattern). Each field shows its source — if it's controlled
   by F&F admin (org-assigned email), say so inline with a small lock icon.
3. Security card. Sign-in security primary; password change, sign-in history.
4. MFA card. Adaptive button (see #5) plus the list of enrolled factors.
5. Active sessions card. List with device, browser, location (approx by IP),
   last seen. Per-row Sign out; "Sign out all other sessions" prominent
   above. Current session row is annotated "This device" with no destructive
   action on it.
6. Plain-English session naming. "Chrome on Mac" beats raw user-agent string;
   show raw UA in a tooltip only.
7. Single revoke event. "Sign out all other sessions" requires step-up; it is
   one of the strongest containment moves an operator has after a suspected
   compromise and must be one click after step-up.
8. Audit trail link. Bottom of every card, "View security activity" linking
   to the dedicated audit surface (Codex's audit logs); don't duplicate the
   audit log inside My Account.

**Avoid.**

- Spreading account settings across multiple top-level routes (Profile,
  Security, etc.) without a unifying parent. Operators end up hunting.
- Forgetting to mark the current session — operators have terminated their
  own session many times across many products.
- Listing IP addresses without approximate location. Most managers cannot
  recognize an IP, but they recognize "Calgary".
- Letting destructive actions live next to inline edits without separation
  (a bumped Sign-out-all click while editing the phone field).

**Operator fit.**

This is the surface managers hit when something feels off ("did I get hacked?",
"why am I signed out?"). It must be immediately scannable: green check on
"Your account is secure" if everything is healthy, red banner with one CTA if
not.

---

## 9. Inheritance Tree Visualization (Additive to Codex's Scope Pane)

Goal: the Codex scope pane is a hierarchy selector. This item is the visual
representation of inheritance on top of it — showing how a setting flows from
Business -> Org unit -> Location, and where overrides exist.

**References.**

- Microsoft Entra ID "inherit from default" — child scopes show "Inherited from default" with the source row inline. [docs](https://learn.microsoft.com/en-us/entra/external-id/tenant-restrictions-v2)
- GitHub Enterprise policy inheritance — org-level policy with per-repo override; inherited value renders faded read-only + "Change" button.
- Pega rule resolution / dependent roles — shows which hierarchy level a rule resolved from. [academy](https://academy.pega.com/topic/permission-inheritance-and-dependent-roles/v4)
- React tree libraries with expand/collapse + filter — MUI X, PrimeReact. [mui](https://mui.com/x/react-tree-view/) [primereact](https://primereact.org/tree/)
- Cascade Strategy permission inheritance — walks from the top of the tree. [help](https://support.cascade.app/access-and-permissions)

**Principles.**

1. Inheritance is rendered next to (not inside) the scope pane. The scope
   pane picks rows; the inheritance visualization is a secondary panel or
   inline annotation on the value being edited. Do not nest the inheritance
   tree inside the scope tree (two trees side by side is confusing).
2. Per-value resolution trail. For each setting that resolves through
   inheritance, show "Business default = 3.5%; Org unit override = 4.0%
   (active); Location override = none". This is the format Pega uses and
   maps cleanly to the F&F Hard Promise #11 ("lower configured scopes
   override higher scopes").
3. Visual diff on overrides. The active value gets a colored dot or chip;
   the inherited values are dimmed. A "Reset to inherited" link is the
   undo affordance.
4. Indeterminate-style annotation when looking at a parent scope whose
   children diverge. If at Business scope and 2 of 5 locations have an
   override, the value field is mixed-state. Indicate inline:
   "Mixed — 3 use 3.5%, 2 use 4.0%. View by location." Indeterminate
   checkbox pattern translates to settings.
   https://www.w3.org/WAI/ARIA/apg/patterns/checkbox/examples/checkbox-mixed/
5. Collapsibility. Inheritance details collapse by default to an inline chip
   ("Inherited from business"). Click to expand the resolution trail. Default
   state is concise; advanced state is exhaustive.
6. Mobile: list, not tree. Mobile collapses the inheritance vis to a single
   resolved value with a "Why?" link. Trees do not fit on phones.

**Avoid.**

- Showing the entire tree all the time. Operators with 50 locations will
  scroll forever.
- Hiding the source. The point is operator trust: managers must be able to
  answer "where does this number come from?" in one tap.
- Treating "no override" and "override = same as parent" the same. Operators
  setting an explicit equal value is a real edit (it pins the value to the
  current parent value at edit time); show it as an override.
- Letting the inheritance vis disagree with what the underlying engine
  resolves. This is the single bug class to actively test; render straight
  from the resolver.

**Operator fit.**

The mental model that works for restaurant managers is "company default,
then group, then location, and the lowest one wins". Use those words. Avoid
"override", "inherit", and "scope" in primary copy where possible; use
"company default", "this group", "this location".

---

## 10. Hierarchy Breadcrumbs Following the User

Goal: a persistent breadcrumb that shows where in the hierarchy the user is
currently scoped, and lets them step up or sideways without re-opening the
scope pane.

**References.**

- Stripe Connect — top breadcrumb "Account > Customer X > Subscription Y" persists across deep pages; clicking any node returns there.
- Linear — project breadcrumb in header, team/workspace context always visible. [WorkOS](https://workos.com/blog/multi-tenant-permissions-slack-notion-linear)
- AWS Console region/account selector — persistent header that doubles as breadcrumb + switcher; never lies about scope.
- NN/G breadcrumbs. [link](https://www.nngroup.com/articles/breadcrumbs/) Smashing breadcrumbs. [link](https://www.smashingmagazine.com/2009/03/breadcrumbs-in-web-design-examples-and-best-practices/)

**Principles.**

1. Location breadcrumbs (where in the data tree), not path breadcrumbs
   (history). Operators must see Business > Org unit > Location, not
   Dashboard > Reports > Last-clicked.
2. Persistent across function-pane navigation. When the operator picks a
   location in the scope pane and walks through Data Accuracy, Polling,
   Integrations — the breadcrumb at the top of each surface stays the same
   and pins the scope. The breadcrumb is the contract that the function-pane
   is reading the correct row.
3. Each segment is a clickable jump back to that level. Clicking Org unit
   level scopes the active function pane up one level. Clicking Business
   collapses to all-locations view. This is Stripe's pattern.
4. Last segment is bold and non-link (current scope). The penultimate is the
   most-tapped target; size accordingly.
5. Overflow ellipsis for deep paths. If the path is longer than the header
   can show (e.g., 5+ ltree segments), ellipsis the middle, keep the root
   and the leaf, expand on hover/tap.
6. Mobile: collapse to "Location: [name] >" with a single tap to open the
   scope pane. Full breadcrumb is desktop-only.
7. Read-only audiences. Breadcrumb must never be the sole destructive
   affordance — never put a delete or suspend menu on a breadcrumb segment.
   Reserve it as a switcher only.

**Avoid.**

- Path-history breadcrumbs that change on every click. Useless for
  hierarchy-scoped surfaces.
- Letting the breadcrumb desynchronize from the scope pane after a Back
  button press.
- Hiding the breadcrumb under a hamburger on desktop. It's the most
  trust-eroding move possible.
- Truncating from the wrong end (you should preserve the leaf, not the
  root).

**Operator fit.**

Multi-location operators live in the breadcrumb. Single-location operators
will never look at it — but the persistent presence reassures them they
haven't accidentally wandered into another business's data, which is the
multi-tenant trust anchor.

---

## 11. Cancel Pending Invite

Goal: explicit Cancel button per pending invite, plain-English confirmation,
clear feedback that the token is revoked.

**References.**

- Vercel Pending Invitations — pending invites separated from active members; per-row Cancel. [docs](https://vercel.com/docs/rbac/managing-team-members)
- Dropbox manage invitations — pending list with per-row Revoke; row shows email, role, invited-by, when. [help](https://help.dropbox.com/account-access/manage-invitations)
- Codecademy pending invites — "Pending" tab with cancel per row. [help](https://help.codecademy.com/hc/en-us/articles/360051798873)
- Frontitude two-step confirmation. [guide](https://www.frontitude.com/guides/invite-members-to-your-workspace)

**Principles.**

1. Separate Pending list from Members list. Either a tab or a clearly
   delineated section at the top of the People surface. Mixing pending and
   active members forces operators to scan a Status column to tell who
   actually has access.
2. Per-row Cancel with role + invited-by visible. The confirmation modal
   restates the invitee's email and role: "Cancel invite for
   chef@bistro.com (Manager role)? They will not be able to use the link
   they were emailed."
3. Token revocation is server-side and immediate. The previously emailed
   link returns a friendly 410 page ("This invite was canceled. Ask
   [inviter] for a new link.") rather than a generic error. This is the
   piece most products skip; restaurant managers will get confused calls
   from invitees if the canceled link says "internal error".
4. Toast feedback after cancel: "Invite to chef@bistro.com canceled.
   Resend?" with an Undo within 10 seconds (fires a fresh invite to the
   same email + role).
5. Audit log entry. "Canceled invite to X by Y at Z." The audit row should
   appear in the same People surface in a small activity strip.
6. Bulk cancel for selected pending rows. Operators who invite via spreadsheet
   sometimes need to undo a batch.

**Avoid.**

- Hiding the Cancel inside a kebab when the row has only two real actions
  (Resend, Cancel). Show both as inline icon buttons.
- Re-issuing the same token after cancel (security regression).
- Silent failure when the invitee already accepted between the cancel click
  and the server processing. Modal must surface "This person has already
  joined. Remove them from members instead?" with a one-tap pivot.
- Letting an outside-the-grace cancel happen without auditing.

**Operator fit.**

The "I sent the invite to the wrong email" moment is what this surface exists
for. Speed and clarity beat elegance.

---

## 12. Edit User Inline (Replacing 3-Dot Menu)

Goal: inline edit of email, name, role, hierarchy assignment in the user table.

**References.**

- PatternFly inline edit — pencil enters edit, check commits, X cancels; tab across cells. [link](https://www.patternfly.org/components/inline-edit/design-guidelines/)
- Linear member role chip — click role, popover, select, apply. [docs](https://linear.app/docs/members-roles)
- Notion sharing dropdowns — per-row permission dropdown commits on selection. [help](https://www.notion.com/help/sharing-and-permissions)
- DataTables Editor with KeyTable — Excel keyboard nav. [link](https://editor.datatables.net/examples/extensions/keyTable.html)
- UX Design World on inline-editing tables. [link](https://uxdworld.com/inline-editing-in-tables-design/)

**Principles.**

1. Click-the-field to edit. Don't require a per-row pencil if every row is
   editable; the pencil pattern is right for sparse-editable rows. People
   table has 3-4 editable fields per row, so click-to-edit on each is OK.
2. Field-level commit semantics by risk. Name = save on blur (low risk).
   Email = save on blur + confirmation toast ("Sent verification to new
   address"). Role = popover with the cascade preview from item #1 (because
   role changes a lot of access). Hierarchy assignment = modal, not inline,
   because it can cascade across the user's entire visible data set.
3. Show effective changes inline. After committing a role change, the user
   sees a small chip next to the cell: "Updated 4s ago — Undo".
4. Hierarchy assignment is the exception. Never inline; it deserves a modal
   with the scope pane (Codex's component) embedded, plus a confirmation
   that names the org unit / location and the resulting access change.
5. Keyboard nav. Tab moves across editable cells in a row; Enter commits;
   Shift+Tab back. This is Excel ergonomics and the only way to make bulk
   edits feasible.
6. Permission. The edit affordance must only render for operators with
   `members.write` (or equivalent). Read-only viewers see static text.
7. Replace the 3-dot menu only for safe edits. Destructive operations
   (Remove from team, Suspend, Force sign-out) still live behind a menu
   because they should NOT be inline.

**Avoid.**

- Inline editing hierarchy assignment with a small popover. Cascading
  changes that affect what the user sees across the app deserve a confirmable
  modal.
- Saving the email field silently when the user typo'd. Always verify the
  new email; do not change auth identity client-side.
- Allowing inline role downgrade for the operator's own row (self-locking).
  Render their own role row as read-only or require a confirm with text
  match.
- Removing the 3-dot menu entirely. Sensitive operations still need
  intentional friction.

**Operator fit.**

The 3-dot menu is universally hated for high-frequency edits. Inline is
faster but loses the "intentional act" cue. The hybrid (inline for safe
edits, menu for destructive) is the only pattern that survives both
audiences.

---

## Cross-Item Notes

- Reuse Codex's scope pane as the universal hierarchy selector across items #3, #4, #6, #9, #10, #11, #12. No parallel hierarchy picker anywhere in the post-Codex wave.
- Items #1, #2, #5, #6 define the security surface — plan as one design sweep so step-up auth, MFA states, deep-link fresh-MFA, and role editing share the same modal patterns and the same step-up component.
- Items #3 and #9 share a "live calculation + inheritance from a parent value" mental model — the inheritance vis (#9) should be reusable by the wage mix table (#3).
- Item #7 (notifications) is the only surface needing real-time socket / push; treat as backend-first with explicit cross-device acceptance tests.
- Item #4 (demo toggle) is the highest HP #2 risk — keep it as a read-out + connect-vendor CTA, never a writer affordance.

All URLs are cited inline at the point of use. Primary sources: Stripe, Linear, GitHub, Microsoft 365 / Entra, Salesforce, Auth0, Notion, Shopify, Vercel, Slack engineering, 7shifts, Toast, PatternFly, W3C ARIA, NN/G, Smashing Magazine, LogRocket, monday.com, Pega, MUI / PrimeReact, Dropbox, Codecademy, Curity, TalentLMS, Courier.
