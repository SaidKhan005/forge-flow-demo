# Admin vs Operator-Web: Screen-by-Screen Cleanliness Comparison

Date: 2026-05-23
Author: worktree audit agent (read-only)
Scope: every screen body, dialog, banner, empty/loading/error state, and section
heading in the operator-web console and the admin console.
Gold standard: the operator-web console (`lib/operator_web/**`). The operator's
directive: "operator-web is the clean one; bring EVERY admin screen up to match
it."

## Method

1. Built the full screen inventory for both consoles (`lib/operator_web/screens/**`,
   `lib/operator_web/widgets/**`, `lib/admin/screens/**`, `lib/admin/widgets/**`,
   `lib/admin/admin_routes.dart`), paired each admin screen with its operator-web
   functional twin, and marked admin-only screens (no twin) for cleanliness-by-
   principle.
2. Read both implementations of each pair and compared on: spacing/padding,
   alignment (especially centre alignment), buttons, wording/copy, UX clutter, and
   all UX surfaces (dialogs, banners, empty states, info buttons, scope notices,
   section headings).
3. Reuse, don't re-derive: Slices A-D7 + B + C already moved admin onto the shared
   `lib/widgets/console/**` kit (`OperatorWebPanel`, `OperatorWebScreenHeader`,
   `OperatorWebSectionHeading`, `OperatorWebInfoButton`, `OperatorWebBanner`, the
   dialog helpers) and aligned the nav rail, the top-bar scope picker, and most
   section chrome. Those structural moves are NOT re-flagged here. This audit
   reports the RESIDUAL cleanliness gaps that remain.
4. Honest assessment: where a screen already matches operator-web it is recorded
   as "matches" rather than inventing work.

## The two structural gold-standard facts that drive most findings

These two facts from the gold standard explain the bulk of the HIGH findings:

- **Centred, width-capped body.** Every operator-web screen wraps its content in
  `OperatorWebScreenBody` (`lib/widgets/console/console_screen_body.dart`): a
  scroll view whose child is `Center`ed and capped at `maxContentWidth` (default
  1120), with edge padding around `EdgeInsets.all(28)` or
  `fromLTRB(24, 24, 24, 32)`. On a wide monitor the content stays balanced with
  even left/right margins. The doc comment names the Data accuracy screen as the
  layout the operator standardised on.
- **Playfair identity header.** Every operator-web screen's title block is
  `OperatorWebScreenHeader` (`lib/widgets/console/console_screen_header.dart`): a
  22px `AppColors.sunsetDark` leading icon + a `display20` (20px Playfair) title,
  optional `body13` subtitle, trailing actions that collapse below a width.

The admin console has a competing local layout kit in
`lib/admin/widgets/admin_responsive_layout.dart` (`AdminPageHeader`, `AdminCard`,
`AdminStatStrip`, `AdminDetailRow`) and several screens still frame themselves with
a bare `Container(color: backgroundDeep)` + `Padding(EdgeInsets.all(20))` instead
of `OperatorWebScreenBody`. `AdminPageHeader` renders the title in
`AppTextStyles.pageTitle` (28px **sans-serif** bold) with no leading icon, which is
a different font, size, and weight from the gold-standard `display20` Playfair
header.

Net effect the operator can see: on the admin console several screens run
edge-to-edge on a wide window (no centre cap) and several show a large sans-serif
title where operator-web shows a smaller Playfair title with an icon.

## Per-screen findings

Legend: HIGH = clearly looks different / cluttered / misaligned at a glance;
LOW = cosmetic nit. "Matches?" = does the screen already match operator-web on the
dimensions audited.

| Screen (admin) | Operator-web reference (file) | Admin file(s) | Divergences (by dimension, file:line) | Recommended fix | Severity | Already matches? |
|---|---|---|---|---|---|---|
| Team members | `lib/operator_web/screens/members_screen.dart` (uses `OperatorWebScreenBody` body675-677 + `OperatorWebScreenHeader` 681) | `lib/admin/screens/members_admin_screen.dart` | ALIGNMENT/SPACING: body frame is bare `Container(backgroundDeep)`+`Padding(EdgeInsets.all(20))` (898-900), not `OperatorWebScreenBody`: no centre, no max-width cap, edge padding 20 vs 24/28. HEADER: `AdminPageHeader` (904) = `pageTitle` 28px sans, no icon, vs `OperatorWebScreenHeader` display20 Playfair + 22px icon. CLUTTER: extra `_PeopleAccessScopeCard` scope-pill strip (928) the operator-web twin does not carry; empty state is a bare `Padding` Text (1420-1427) vs operator-web's bordered empty card (959-986). | Wrap body in `OperatorWebScreenBody(maxContentWidth: 1120)`; swap `AdminPageHeader` for `OperatorWebScreenHeader(icon: Icons.group_outlined, title: 'Team members')`; wrap the empty state in a bordered surface like operator-web. | HIGH | No |
| Roles & permissions / Team access | `lib/operator_web/screens/roles_screen.dart` + `sessions_screen.dart` + `hierarchy_screen.dart` (OperatorWebScreenBody + OperatorWebScreenHeader) | `lib/admin/screens/roles_hierarchy_sessions_admin_screen.dart` | ALIGNMENT/SPACING: bare `Container(backgroundDeep)`+`Padding(all(20))` (490-494), no centre / no width cap. HEADER: `AdminPageHeader` (498) sans-28 vs Playfair-20+icon. (Tabs + RolePolicyAdminPanel already use shared panels - good.) | Wrap in `OperatorWebScreenBody`; swap to `OperatorWebScreenHeader(icon: Icons.account_tree_outlined)`. | HIGH | No |
| Audit log (support actions) | `lib/operator_web/screens/audit_log_screen.dart` (OperatorWebScreenBody body651-653 padding fromLTRB(24,24,24,32) + OperatorWebScreenHeader 755) | `lib/admin/screens/audited_support_actions_admin_screen.dart` | ALIGNMENT/SPACING: bare `Container(backgroundDeep)`+`Padding(all(20))` (566-568), no centre / no cap. HEADER: `AdminPageHeader` (572) sans-28 vs Playfair-20+icon. (Inner regions already use `OperatorWebPanel` 729/916/1147 - good.) | Wrap in `OperatorWebScreenBody`; swap to `OperatorWebScreenHeader(icon: Icons.security_outlined, title: 'Audit log')`. | HIGH | No |
| Default roles | `lib/operator_web/screens/roles_screen.dart` (gold-standard frame) | `lib/admin/screens/default_role_catalog_admin_screen.dart` | ALIGNMENT/SPACING: header is `OperatorWebScreenHeader` (429 - good) but body frame is bare `Container(backgroundDeep)`+`Padding(all(20))` (350-352), not `OperatorWebScreenBody`: no centre / no cap. | Wrap body in `OperatorWebScreenBody`. (Header already correct.) | HIGH | Partial (header yes, body no) |
| Vendor Applicability | (admin-only family; nearest twin = operator-web data-accuracy frame) | `lib/admin/screens/vendor_applicability_admin_screen.dart` | ALIGNMENT/SPACING: header `OperatorWebScreenHeader` (253 - good) but body bare `Container(backgroundDeep)`+`Padding(all(20))` (245-248), no centre / no cap. | Wrap body in `OperatorWebScreenBody`. | HIGH | Partial (header yes, body no) |
| Plans and limits (Pricing) | operator-web data-accuracy / wage frame (OperatorWebScreenBody + OperatorWebScreenHeader) | `lib/admin/screens/pricing_tier_admin_screen.dart` | ALIGNMENT/SPACING: header `OperatorWebScreenHeader` (209 - good) but body bare `Container(backgroundDeep)`+`Padding(all(20))` (201-205), no centre / no cap. Standalone mount only (route mounts inside the scope workspace pane). | Wrap body in `OperatorWebScreenBody`. | HIGH | Partial (header yes, body no) |
| Connected services (Integrations) | operator-web `vendor_connections_screen.dart` frame | `lib/admin/screens/integration_admin_screen.dart` | ALIGNMENT/SPACING: header `OperatorWebScreenHeader` (367 - good) but body bare `Container(backgroundDeep)`+`Padding(all(20))` (220-222), no centre / no cap. Renders inside scope workspace pane (narrower); divergence is mainly the missing centre cap on wide panes. | Wrap body in `OperatorWebScreenBody`. | LOW | Partial (header yes, body no) |
| System health | operator-web gold-standard frame | `lib/admin/screens/health_admin_screen.dart` | ALIGNMENT/SPACING: header `OperatorWebScreenHeader` (446 - good) but body bare `Material(backgroundDeep)`+`Padding(all(20))` (310-313), no centre / no cap. Inside scope workspace pane. | Wrap body in `OperatorWebScreenBody`. | LOW | Partial (header yes, body no) |
| AI Metrics (Observability) | operator-web gold-standard frame | `lib/admin/screens/observability_admin_screen.dart` | ALIGNMENT/SPACING: header `OperatorWebScreenHeader` (375 - good) but body bare `Material(backgroundDeep)`+`Padding(all(20))` (218-223), no centre / no cap. Inside scope workspace pane. | Wrap body in `OperatorWebScreenBody`. | LOW | Partial (header yes, body no) |
| Launch controls (Feature flags) | operator-web gold-standard frame | `lib/admin/screens/feature_flags_admin_screen.dart` | ALIGNMENT/SPACING: header `OperatorWebScreenHeader` (331 - good) but body bare `Container(backgroundDeep)`+`Padding(all(20))` (205-209), no centre / no cap. Inside scope workspace pane. | Wrap body in `OperatorWebScreenBody`. | LOW | Partial (header yes, body no) |
| Knowledge base (Corpus) | operator-web gold-standard frame | `lib/admin/screens/corpus_admin_screen.dart` | ALIGNMENT/SPACING: header `OperatorWebScreenHeader` (1600 - good) but body bare `Container(backgroundDeep)`+`Padding(all(20))` (334-336), no centre / no cap. Inside scope workspace pane. | Wrap body in `OperatorWebScreenBody`. | LOW | Partial (header yes, body no) |
| Support logs (Debug console) | operator-web gold-standard frame | `lib/admin/screens/debug_console_admin_screen.dart` | HEADER: `_Header` returns `AdminPageHeader` (704) sans-28, not `OperatorWebScreenHeader`. ALIGNMENT/SPACING: main view bare `Material(backgroundDeep)`+`Padding(all(20))` (550-555); a sub-view already uses `OperatorWebScreenBody` (1848) so the screen is internally inconsistent. | Swap `_Header` to `OperatorWebScreenHeader(icon: Icons.bug_report_outlined, title: 'Support logs')`; wrap the main body in `OperatorWebScreenBody`. | HIGH | No |
| Data accuracy (per-location) | `lib/operator_web/screens/data_accuracy_screen.dart` (OperatorWebScreenBody body1135 padding fromLTRB(28,28,28,40) + OperatorWebScreenHeader 1141) | `lib/admin/screens/per_location_data_accuracy_screen.dart` | ALIGNMENT/SPACING: standalone body bare `Container(backgroundDeep)`+`Padding(all(20))` (244-248), no centre / no cap. HEADER: `AdminPageHeader` (253) sans-28 vs Playfair-20+icon. Note: route mounts this inside the scope workspace pane with `showPageHeader=false` (252), so the divergence is visible only in the standalone mount. | Wrap body in `OperatorWebScreenBody`; swap the (gated) header to `OperatorWebScreenHeader(icon: Icons.fact_check_outlined)`. | LOW | Partial (header gated, body no) |
| Polling Setup | operator-web data-accuracy / polling-tier frame | `lib/admin/screens/polling_and_pricing_admin_screen.dart` | ALIGNMENT/SPACING: standalone body bare `Container(backgroundDeep)`+`Padding(all(20))` (581-583), no centre / no cap. HEADER: gated `AdminPageHeader` (588) sans-28. Route mounts inside the scope workspace pane with `showPageHeader=false`. | Wrap body in `OperatorWebScreenBody`; swap the (gated) header to `OperatorWebScreenHeader`. | LOW | Partial (header gated, body no) |
| Timing | operator-web `business_timing_editor_screen.dart` frame | `lib/admin/screens/admin_timing_setup_screen.dart` | MATCHES the centring rule: already uses `OperatorWebScreenBody(maxContentWidth: 880, padding: all(20))` (51-53). Minor: no leading-icon screen header (it is a scoped sub-pane with the workspace header above it), which is acceptable. | No action (verify the 880 cap is intentional vs the 1120 default). | LOW | Yes (centred) |
| My account | `lib/operator_web/screens/my_account_screen.dart` (OperatorWebScreenBody all(28) + OperatorWebScreenHeader; OperatorWebPanel padding fromLTRB(18,16,18,18)) | `lib/admin/screens/my_account_admin_screen.dart` | MATCHES: `OperatorWebScreenBody(all(28))` (183), `OperatorWebScreenHeader` (225), `OperatorWebPanel` with the SAME `fromLTRB(18,16,18,18)` padding (261). Only LOW: the Edit-identity dialog hand-rolls a bare `Dialog`+`Padding(all(20))`+`Row(MainAxisAlignment.end)` for actions (1604-1610) instead of `OperatorWebDialog`/`showOperatorWebDialog`. | Optional: migrate the Edit-identity dialog to `showOperatorWebDialog` for one consistent dialog chrome + close affordance. | LOW | Yes (screen body) |
| Notifications | `lib/operator_web/screens/settings_notifications_screen.dart` (OperatorWebScreenBody all(28) + OperatorWebScreenHeader + OperatorWebPanel + OperatorWebBanner) | `lib/admin/screens/admin_notification_preferences_screen.dart` | MATCHES: near byte-identical frame - `OperatorWebScreenBody(all(28))` (277), `OperatorWebScreenHeader` (330), `OperatorWebPanel` per category (410), `OperatorWebBanner` for disconnect/error (362/380), same state badges + toggles. Only LOW: operator-web shows a per-row `OperatorWebInfoButton` next to each state badge (settings_notifications_screen.dart:466); admin uses static subcopy text instead (admin:484-494). Both honest; not a defect. | No action. | LOW | Yes |
| Business accounts (operator/location landing) | admin-only (no operator-web twin) | `lib/admin/screens/operator_location_admin_screen.dart` | ADMIN-ONLY. Uses `AdminCard` (1075) + `AdminDetailRow` (1099) + `display20` title inside the card. `AdminCard` carries a box shadow (admin_responsive_layout.dart:152-158) where the shared `OperatorWebPanel` is flat (no shadow); radius 8 on both. Mild inconsistency vs the kit, not "broken". | Optional: migrate the operator/location detail cards from `AdminCard` to `OperatorWebPanel` so the card treatment (flat, hairline) matches. | LOW | Mostly (admin-only, principled) |
| Support workspace (scope pane + function pane) | admin-only (no operator-web twin) | `lib/admin/widgets/admin_setup_workspace.dart` | ADMIN-ONLY master/detail. The function-pane `_WorkspaceHeader` (662-732) renders the title in `AppTextStyles.sectionTitle` (16px sans) + `account_tree` icon 20px - smaller/different from `OperatorWebScreenHeader` display20. Scope-pane tree cards + empty state use `AdminCard` (419/739). This is the wrapper around Pricing/Corpus/Integrations/Health/Observability/FeatureFlags/DataAccuracy/Polling, so its header sets the visual tone for all of them. | Align `_WorkspaceHeader` title to `display20` Playfair to match the screen-header scale (keep the master/detail layout, which is intentional admin IA). | LOW | Mostly (admin-only, principled) |
| Top-bar scope picker | `lib/operator_web/widgets/web_app_shell.dart` `_ManagementScopePicker` (hierarchy-map popover) | `lib/admin/widgets/admin_scope_picker.dart` | MATCHES the kit: uses `showOperatorWebDialog` (88), `OperatorWebBanner` for errors (777), plain-English `·`-separated label, no em dash. Trigger chrome is a clean bordered control. | No action. | LOW | Yes |
| Invite member dialog | `lib/operator_web/screens/invite_member_dialog.dart` | `lib/admin/screens/invite_member_admin_dialog.dart` | Reuses the shared hierarchy pickers + `console_surface` import; adds the required `admin_reason` field (intentional admin-path asymmetry, per the parity contract). Buttons use `AdminButtonStyles` (chipLabel/sans). LOW: admin dialog title uses `AdminButtonStyles.dialogTitleStyle` (sans-20) where operator-web dialog titles use `display20` (Playfair-20). | Optional: align dialog title style to `display20`. Keep the admin_reason field. | LOW | Mostly |
| (orphan) Audit log standalone | `lib/operator_web/screens/audit_log_screen.dart` | `lib/admin/screens/audit_log_admin_screen.dart` | NOT MOUNTED IN ANY ROUTE (called "the orphan AuditLogAdminScreen" at audited_support_actions_admin_screen.dart:713). Its hand-rolled `_buildHeader` uses `display28` (a third header style, no icon, 271-289) and a plain Material `ElevatedButton` "Run filter" (245) off the sunset button theme. | Dead code: do not invest cleanup here; recommend a separate "remove orphan AuditLogAdminScreen" task rather than restyling. | LOW | n/a (orphan) |

### Cross-cutting (button + dialog systems)

- **Button typography.** `lib/admin/admin_button_styles.dart` themes admin's
  filled/outlined/text buttons app-wide with `AppTextStyles.chipLabel` (12px sans
  w700) labels (39-49, 65-84, 163-169). Operator-web primary buttons use larger
  Playfair labels (e.g. Members invite uses `display16`, members_screen.dart:698).
  So admin buttons read smaller and sans where operator-web reads larger and
  Playfair. This is a *deliberate, uniformly applied* admin button system, not a
  drift, so it is recorded LOW and is NOT placed in a fix wave (changing it is a
  console-wide design decision for the operator, not a residual-cleanliness fix).
- **Dialog titles.** Admin's `AdminButtonStyles.dialogTitleStyle` is `pageTitle`
  forced to 20px sans (15-17); operator-web `OperatorWebDialog` titles are
  `display20` Playfair. Minor, LOW, console-wide.

## Fix-wave plan (HIGH-severity only, grouped so no two waves touch the same file)

Each wave is a single screen file (the fix is "wrap the body in
`OperatorWebScreenBody` and/or swap `AdminPageHeader` to `OperatorWebScreenHeader`").
Grouping by file guarantees no two waves edit the same file, so they can run in
parallel without conflict. None of these waves touch
`lib/admin/admin_routes.dart`, `lib/admin/admin_capability_gate.dart`, or
`lib/admin/services/integration_admin_gateway.dart`.

The HIGH set is the screens that diverge on BOTH centring and header (or are
internally inconsistent): the four full-screen surfaces mounted directly in the
shell, plus the two header-correct-but-uncentred screens whose standalone mount is
full-width.

- **Wave H1 - Team members.** Files: `lib/admin/screens/members_admin_screen.dart`.
  Wrap body in `OperatorWebScreenBody(maxContentWidth: 1120, padding: EdgeInsets.fromLTRB(24,24,24,32))`;
  replace `AdminPageHeader` with `OperatorWebScreenHeader(icon: Icons.group_outlined, title: 'Team members', actions: [...])`;
  wrap the members empty state in a bordered surface.
- **Wave H2 - Roles & permissions.** Files:
  `lib/admin/screens/roles_hierarchy_sessions_admin_screen.dart`. Wrap body in
  `OperatorWebScreenBody`; replace `AdminPageHeader` with
  `OperatorWebScreenHeader(icon: Icons.account_tree_outlined)`.
- **Wave H3 - Audit log (support actions).** Files:
  `lib/admin/screens/audited_support_actions_admin_screen.dart`. Wrap body in
  `OperatorWebScreenBody`; replace `AdminPageHeader` with
  `OperatorWebScreenHeader(icon: Icons.security_outlined, title: 'Audit log')`.
- **Wave H4 - Support logs (Debug console).** Files:
  `lib/admin/screens/debug_console_admin_screen.dart`. Swap the `_Header`
  `AdminPageHeader` for `OperatorWebScreenHeader(icon: Icons.bug_report_outlined,
  title: 'Support logs')`; wrap the main-view body in `OperatorWebScreenBody` so it
  matches the sub-view that already uses it.
- **Wave H5 - Default roles.** Files:
  `lib/admin/screens/default_role_catalog_admin_screen.dart`. Wrap body in
  `OperatorWebScreenBody` (header already correct).
- **Wave H6 - Vendor Applicability.** Files:
  `lib/admin/screens/vendor_applicability_admin_screen.dart`. Wrap body in
  `OperatorWebScreenBody` (header already correct).
- **Wave H7 - Plans and limits (Pricing, standalone).** Files:
  `lib/admin/screens/pricing_tier_admin_screen.dart`. Wrap body in
  `OperatorWebScreenBody` (header already correct).

Optional LOW follow-up waves (each its own file, also non-conflicting), if the
operator wants the centre cap everywhere rather than only on the full-width
surfaces:

- LOW-L1 `lib/admin/screens/integration_admin_screen.dart` (body cap).
- LOW-L2 `lib/admin/screens/health_admin_screen.dart` (body cap).
- LOW-L3 `lib/admin/screens/observability_admin_screen.dart` (body cap).
- LOW-L4 `lib/admin/screens/feature_flags_admin_screen.dart` (body cap).
- LOW-L5 `lib/admin/screens/corpus_admin_screen.dart` (body cap).
- LOW-L6 `lib/admin/screens/per_location_data_accuracy_screen.dart` (body cap +
  gated header).
- LOW-L7 `lib/admin/screens/polling_and_pricing_admin_screen.dart` (body cap +
  gated header).
- LOW-L8 `lib/admin/widgets/admin_setup_workspace.dart` (`_WorkspaceHeader` title
  to Playfair display20).
- LOW-L9 `lib/admin/screens/my_account_admin_screen.dart` (Edit-identity dialog to
  `showOperatorWebDialog`).
- LOW-L10 `lib/admin/screens/operator_location_admin_screen.dart` (`AdminCard` to
  `OperatorWebPanel` for the detail cards).
- LOW-L11 `lib/admin/screens/invite_member_admin_dialog.dart` (dialog title to
  `display20`).

### auth-file-touch, defer

None of the cleanliness fixes above require editing `lib/admin/admin_routes.dart`,
`lib/admin/admin_capability_gate.dart`, or
`lib/admin/services/integration_admin_gateway.dart`. The fixes live entirely in the
screen/widget files. No auth-file-touch items were found.

Note: the screens whose page header is gated behind `showPageHeader` (Pricing,
Polling, Per-location data accuracy) are passed `showPageHeader: false` from
`lib/admin/admin_routes.dart` when mounted inside the scope workspace. The fix-wave
edits stay inside the screen files; they do NOT change the route builders' header
gating.

## Already clean / no action (coverage of every screen)

Operator-web screens (the references) - all already use the shared kit by
definition; not re-listed individually.

Admin screens that match the gold standard on the audited dimensions (no action):

- **My account** (`my_account_admin_screen.dart`) - matches: `OperatorWebScreenBody`,
  `OperatorWebScreenHeader`, `OperatorWebPanel` at the same padding.
- **Notifications** (`admin_notification_preferences_screen.dart`) - matches:
  near byte-identical frame to the operator-web Notifications screen.
- **Timing** (`admin_timing_setup_screen.dart`) - matches the centring rule
  (`OperatorWebScreenBody(maxContentWidth: 880)`).
- **Top-bar scope picker** (`admin_scope_picker.dart`) - matches: shared dialog +
  banner + plain-English label.

Admin screens already correct on the HEADER dimension (only the body-cap remains,
tracked as LOW above): Integrations, System health, AI Metrics, Launch controls,
Knowledge base, Vendor Applicability, Plans and limits.

Admin-only screens (no twin) judged clean-by-principle: the Business accounts
landing and the Support workspace master/detail are intentional admin IA; only the
LOW card/header-scale nits noted above apply.

Orphan / dead code: `audit_log_admin_screen.dart` is not mounted; recommend removal
in a separate task rather than restyling.

## Honest summary

- Admin is already substantially on the shared kit. The headline residual gap is
  uniform and mechanical: many admin screens are not wrapped in
  `OperatorWebScreenBody`, so they lose the centre + max-width cap the operator
  standardised on, and a cluster of full-screen surfaces still use the sans-serif
  `AdminPageHeader` instead of the Playfair `OperatorWebScreenHeader`.
- Two screens (My account, Notifications) and the top-bar scope picker and Timing
  setup already match - no manufactured work there.
- The button/dialog typography difference is a deliberate, uniformly applied admin
  system, not drift; it is recorded but intentionally left out of the fix waves.
