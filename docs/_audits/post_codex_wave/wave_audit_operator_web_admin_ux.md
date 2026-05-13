# Wave Audit — Operator-Web + Admin UX

**Master tip:** 63b67753
**Auditor:** read-only agent (4 of 8)
**Dimension:** Operator-Web + Admin UX (HP #11 compliance, file-size ceiling, 2-console framing, UX writing, Metric Honesty, Inheritance Tree consumer, demo posture, em-dash regression, C-10 framing, Mobile read-mostly)
**Wave scope:** every operator-web (`lib/operator_web/`) and admin (`lib/admin/`) file changed from 2026-04-28 onward (~150 files across 24 operator-web screens + 21 admin screens + supporting widgets + gateways).

---

## Verdict

**APPROVE WITH FINDINGS.** The wave delivered ~24 operator-web screens + ~21 admin screens with a generally healthy UX writing posture, working 2-console boundary, no demo-reader regressions, and Lane C C-10 framing applied consistently. Three material concerns:

1. **F-OW-1 (P1):** `lib/operator_web/screens/my_account_screen.dart` is **2,051 LoC** — **386 LoC over** the 1,665 LoC operator-web ceiling that PR #624 explicitly anchored. Eight further operator-web screens are at or above 800 LoC; three (`members_screen.dart` 1,611; `audit_log_screen.dart` 1,329; `hierarchy_screen.dart` 1,015) are at or above 1,000 LoC. The ceiling needs either enforcement now or a documented raise.
2. **F-OW-2 (P2):** Two wave-touched operator-web screens (`schedule_screen.dart`, `wage_authority_screen.dart`) are per-location editors that **do not display the HP #11 (selected scope, inherited source, effective value) triple** and do not carry an inline exception note. The carve-out is implicit ("you picked the location at the side-nav") but HP #11 mandates an explicit on-surface anchor or a documented exception. Six other surfaces (`business_setup_screen.dart`, `business_timing_editor_screen.dart`, `data_accuracy_screen.dart`, `settings_notifications_screen.dart`, admin's `admin_timing_setup_screen.dart`, admin's `audit_log_admin_screen.dart`) handle this cleanly and serve as positive exemplars.
3. **F-OW-3 (P3):** Em-dash regression test (`test/operator_web/screens/audit_log_screen_test.dart:383-425`) is narrowly scoped to the 4 11W.5-owned files; **the principle is widely violated elsewhere in operator-web** — 45 operator-web files contain U+2014 em-dashes in operator-facing strings. The intent of the regression test is to prevent em-dashes leaking into copy; either the regression should expand, or each em-dash site needs a documented rationale.

No P0 / blocking issues. Inheritance Tree consumer compliance is correct. Demo-mode reader posture is clean. Mobile inbox (C-9) preserved its read-only posture. C-10 admin parity copy applied consistently. Cross-tenant operator-web leakage — none found.

---

## File-size dashboard (operator-web screens, wave-touched)

LoC counted at master `63b67753`. Ceiling per PR #624 audit anchor: **~1,665 LoC**.

| File | LoC | Status |
|---|---|---|
| `my_account_screen.dart` | 2,051 | **OVER (+386)** — F-OW-1 |
| `members_screen.dart` | 1,611 | At ceiling |
| `audit_log_screen.dart` | 1,329 | Under |
| `hierarchy_screen.dart` | 1,015 | Under |
| `data_accuracy_screen.dart` | 992 | Under |
| `roles_screen.dart` | 947 | Under |
| `wage_authority_screen.dart` | 907 | Under |
| `custom_role_editor_screen.dart` | 844 | Under |
| `sessions_screen.dart` | 819 | Under |
| `account_screen.dart` | 731 | Under |
| `business_timing_editor_screen.dart` | 671 | Under |
| `schedule_screen.dart` | 629 | Under |
| `business_setup_screen.dart` | 621 | Under |
| `settings_notifications_screen.dart` | 575 | Under |
| `mfa_enrollment_screen.dart` | 530 | Under |
| `permission_explainer_screen.dart` | 437 | Under |
| `vendor_connections_screen.dart` | 399 | Under |
| Others (< 350 LoC) | varies | All clean |

**Admin screens (wave-touched; informational, no codified ceiling):**

| File | LoC | Note |
|---|---|---|
| `operator_location_admin_screen.dart` | 4,894 | Largest admin screen — admin-side ceiling not codified |
| `roles_hierarchy_sessions_admin_screen.dart` | 2,795 | Composite parity surface |
| `observability_admin_screen.dart` | 2,670 | Multi-tile dashboard |
| `corpus_admin_screen.dart` | 2,415 | RAG / ingest control |
| `members_admin_screen.dart` | 2,204 | Members + invites parity |
| `debug_console_admin_screen.dart` | 2,177 | Per-operator HTTP gateway viewer |
| `audited_support_actions_admin_screen.dart` | 2,009 | Audited-support action log |
| `health_admin_screen.dart` | 1,303 | A6.1 post-honesty pass |
| `polling_and_pricing_admin_screen.dart` | 1,221 | Per-location tier assignment |
| `per_location_data_accuracy_screen.dart` | 1,123 | Per-location DA |
| `pricing_tier_admin_screen.dart` | 1,091 | Tier defs + changes |
| `default_role_catalog_admin_screen.dart` | 987 | B2.2 |
| `integration_admin_screen.dart` | 938 | KMS-stub integration mgmt |
| `vendor_applicability_admin_screen.dart` | 812 | B10.2 |

Admin screens have no codified file-size ceiling. The top three (4894 / 2795 / 2670) are noticeably large; flagging non-blocking for orchestrator awareness.

---

## Wave-new operator-web surfaces — HP #11 compliance

| Screen | Surface kind | HP #11 posture | Verdict |
|---|---|---|---|
| `business_setup_screen.dart` | Read view of hierarchy-scoped timing | Renders `_InheritanceCard` chain + `_EffectiveTimingCard` + per-field "Inherited from {sourceLabel}" annotations (`:560-562`) | **Compliant — exemplar.** |
| `business_timing_editor_screen.dart` | Editor for hierarchy-scoped timing | Header comment line 5 says "*read view (inheritance / effective)*"; editor itself acts on selected scope; provenance pinned via the `Inherited` chip per field | **Compliant — exemplar.** |
| `data_accuracy_screen.dart` | Per-location settings | Mounted under a selected location (router param `locationId`); copy at `:1043` says "*covers from is a business-wide decision. Only…*" — explicit scope copy. **No inheritance triple on every row.** | **Compliant by location-bound design**, but no inline HP #11 exception note. **Minor opportunity:** add a comment block similar to `settings_notifications_screen.dart:38-42`. |
| `settings_notifications_screen.dart` | Per-user notification preferences | Lines 38-42 explicitly document the HP #11 carve-out ("per-(operator, user, event, channel), not hierarchy-scoped"). State badges per row (Available / Coming soon / Backend-only) | **Compliant — exemplar.** |
| `hierarchy_screen.dart` | Hierarchy visualization + mutate (org units / locations) | Uses `_OperatorWebHierarchyInheritanceTree` (the C-6 adopter). Read-mostly for `location_manager`; mutate gated on `team.roles.assign`. Tree IS the hierarchy. | **Compliant.** |
| `audit_log_screen.dart` | Operator's own audit ledger | Hierarchy filter is a B8.b admin-side concern; operator-web `audit_log_screen.dart` is operator-scoped (per the 2-console framing) and intentionally does not expose a hierarchy filter. PR #624 audit doc anchors this decision. | **Compliant — operator-scoped by design.** |
| `my_account_screen.dart` | Per-user account (sign-in identity, MFA, sessions) | Personal preference surface, not org-config. No HP #11 inheritance triple needed. **No inline exception note** — should mirror the `settings_notifications_screen.dart` pattern. | **Compliant by personal-surface design**, but no inline exception note (minor). |
| `account_screen.dart` | Business identity (name, logo, currency, locale, week-start, rollover) | Business-wide settings, not hierarchy-overridable per V1 product scope. No inline HP #11 note. | **Likely compliant** (business-identity ≠ hierarchy-scoped), but worth an explicit note. |
| `members_screen.dart` | Per-user roster | Members + role assignments are per-(operator, user, location) bindings. Filter chip exposes `Location` selector (`:906-924`). Not a settings-override surface. | **Compliant by design — not a settings surface.** |
| `roles_screen.dart` | Role catalog (custom + Default + system) | B2.2 Default-role badge wired (per worker notes). Roles are operator-wide; not hierarchy-scoped. | **Compliant by design.** |
| `custom_role_editor_screen.dart` | Custom role editor | Operator-wide custom roles; not hierarchy-scoped. | **Compliant by design.** |
| `sessions_screen.dart` | Active sessions team view | Audit/security surface, not a settings-override surface. | **Compliant by design.** |
| `schedule_screen.dart` | Locked weekly plan (read view) | **Mounted with `locationId` / `locationName`** props. No "selected scope" header, no source annotation, no inline HP #11 note. | **F-OW-2.** |
| `wage_authority_screen.dart` | Wage role rows editor | **Mounted with `locationId` / `locationName`** props (`:78-81`). Per-location editor. No selected-scope header, no source annotation, no inline HP #11 note. | **F-OW-2.** |
| `mfa_enrollment_screen.dart` | TOTP enrollment | Per-user, not hierarchy-scoped. | **Compliant by design.** |
| `vendor_connections_screen.dart` | Vendor connections placeholder/mount | Per-location (vendor connections are location-bound per HP #11 itself). | **Compliant — location-editable carve-out.** |
| `permission_explainer_screen.dart` | Permission catalog explainer | Read-only catalog; not a settings surface. | **Compliant by design.** |

## Wave-new admin surfaces — HP #11 compliance

| Screen | HP #11 posture | Verdict |
|---|---|---|
| `admin_timing_setup_screen.dart` | Renders "Selected scope", "Timing source", "Covered locations", "Timezone" rows. Inheritance notice at `:170-180` when scope covers multiple locations | **Compliant — exemplar.** |
| `audit_log_admin_screen.dart` | Renders shared `InheritanceTree` widget as visualization PLUS scope dropdown ("Whole business" / "Region / district" / "Single location") — explicit selected scope | **Compliant — exemplar.** |
| `per_location_data_accuracy_screen.dart` | Uses `AdminHierarchySettingsScopePolicy` for `dataAccuracy`. Decorates with `effectiveValueLabel` / `valueState` / `allowedActionsLabel` per scope kind | **Compliant.** |
| `polling_and_pricing_admin_screen.dart` | Uses `AdminHierarchySettingsScopePolicy` for `pollingPricing` (same policy as data accuracy). | **Compliant.** |
| `operator_location_admin_screen.dart` | Carries `AdminHierarchyScopeIntent` through `admin_hierarchy_scope_prompt.dart` + `admin_hierarchy_scope_notice.dart`. Per PR #481 retroactive audit, HP #11 fix landed | **Compliant per PR #481 retroactive audit.** |
| `roles_hierarchy_sessions_admin_screen.dart` | Renders `InheritanceTree` for hierarchy panel (`:1428`) with location-tap handler at `:1431`. Sessions are not hierarchy-scoped by design | **Compliant.** |
| `default_role_catalog_admin_screen.dart` | F&F catalog publish surface; cross-tenant admin surface, not operator hierarchy-scoped | **Compliant by design.** |
| `vendor_applicability_admin_screen.dart` | F&F catalog of which vendors can play which roles; global, not hierarchy-scoped | **Compliant by design.** |
| `members_admin_screen.dart` | Cross-operator members admin (11A.12). Operator + location filters expose visibility scope. | **Compliant by design.** |
| `corpus_admin_screen.dart` | Per-operator corpus admin (11A.3a); operator selection via picker | **Compliant by design.** |
| `pricing_tier_admin_screen.dart` | Tier definitions + change requests; cross-operator surface | **Compliant by design.** |
| `feature_flags_admin_screen.dart` | Cross-operator feature flags | **Compliant by design.** |
| `integration_admin_screen.dart` | KMS-stubbed integrations + key rotation; cross-operator | **Compliant by design.** |
| `health_admin_screen.dart` | A6.1 metric-honest health dashboard (P1 fixes landed) | **Compliant.** |
| `observability_admin_screen.dart` | Bounded-cost observability | **Compliant by design.** |
| `debug_console_admin_screen.dart` | Per-operator HTTP gateway debug | **Compliant by design.** |
| `audited_support_actions_admin_screen.dart` | Audited support actions log | **Compliant by design.** |
| `audit_log_admin_screen.dart` (B8) | Hierarchy filter via `InheritanceTree` | **Compliant — exemplar.** |

---

## Findings

### F-OW-1 (P1) — Operator-web file-size ceiling breach on my_account_screen.dart

**Surface:** `lib/operator_web/screens/my_account_screen.dart` — **2,051 LoC**.
**Authority:** PR #624 audit note (`docs/archive/_audits/post_codex_wave_2026-05-13/pr_624_b8_audit_log_hierarchy_filter_audit.md:21`) — "*Operator-web `audit_log_screen.dart` is 1,416 LoC and would balloon past the 1,665 LoC operator-web ceiling if the hierarchy filter were inlined; worker shipped admin-side only.*" The ceiling is anchored in PR #624 but not yet codified in `CLAUDE.md` or `docs/contracts/`.
**Evidence:**

- The file consolidates four sections (Profile / Security / MFA / Active Sessions) plus three nested dialogs (`_MfaEnrollDialog`, `_BackupCodesDialog`, `_ChangePasswordDialog`).
- B9.2 + B9.3 + C-3 all landed on this file in quick succession (Active Sessions / Adaptive 2FA / Sign-in security fold-in).
- Dialogs alone account for ~600+ LoC (e.g. `_MfaEnrollDialog` starts at `:1707` and runs to `:~1900`).

**Risk:** Future PR auditors will repeatedly cite the ceiling against bug-fix and feature slices on this file, forcing deferrals like PR #624's B8.b mobile/operator-web parity deferral. Sliding ceiling → either enforce or raise.
**Suggested action (out of scope for this audit):**
- (a) Extract the three nested dialogs into peer files (`_change_password_dialog.dart`, `_mfa_enroll_dialog.dart`, `_backup_codes_dialog.dart`), or
- (b) Codify the operator-web file-size ceiling in `CLAUDE.md` / `docs/contracts/operator_web_file_size_ceiling.md` with the rationale and a measured number (e.g. 1,665 hard / 2,500 with documented exception), so future audits have a non-drifting anchor.

### F-OW-2 (P2) — Two per-location editors lack HP #11 scope annotations

**Surfaces:**
- `lib/operator_web/screens/schedule_screen.dart` (629 LoC)
- `lib/operator_web/screens/wage_authority_screen.dart` (907 LoC)

**Authority:** CLAUDE.md HP #11 — "*Every settings, roles, timing, pricing, accuracy, security, support, and future configuration surface must show selected scope, inherited source, and effective value, or document why the capability is backend-only/gated/incomplete.*"

**Evidence:**

- Both screens take a `locationId` + `locationName` prop (`schedule_screen.dart:50-52`, `wage_authority_screen.dart:78-81`), implying the side-nav location picker is the de-facto "selected scope."
- Neither screen renders an on-screen "Selected scope: {locationName}" badge.
- Neither carries an inline `// HP #11 carve-out: …` comment as `settings_notifications_screen.dart:38-42` does.
- Wage Authority is the **target** of the W3.A → W5.A.2 surface migration (wage rows moved off the mobile section to operator-web only). It's an operator-config surface that should anchor to HP #11.
- Schedule is a read view, not an editor, but it presents operator-config-derived output (forecast inputs, locked plan) and HP #11 explicitly enumerates "*timing, pricing, accuracy*" surfaces.

**Risk:** Operators using the side-nav location switcher may not realize the screen reflects the *selected* location only. Wave-new positive exemplars (`business_setup_screen.dart`, `business_timing_editor_screen.dart`, `data_accuracy_screen.dart`, `settings_notifications_screen.dart`, admin's `admin_timing_setup_screen.dart`) all render either a scope header or an inline carve-out note.

**Suggested action:** Add an on-surface "Selected scope: {locationName}" header (low-cost — one widget) OR an inline HP #11 carve-out comment block mirroring the `settings_notifications_screen.dart:38-42` pattern. The comment alone is sufficient since both screens are reached only through the side-nav, but the on-surface header is the more operator-honest path.

### F-OW-3 (P3) — Em-dash regression principle not generalized

**Authority:** `test/operator_web/screens/audit_log_screen_test.dart:383-425` — pins the 4 11W.5-owned files as em-dash free in operator-facing strings.

**Evidence:**

- Grep for `—` (U+2014) in `lib/operator_web/` finds **45 files** containing em-dashes.
- Spot check shows they ARE in operator-facing strings, not just comments. Examples:
  - `lib/operator_web/screens/mfa_enrollment_screen.dart:148` — `stepLabel: 'Step 3 of 4 — Two-factor sign-in'`
  - `lib/operator_web/screens/password_setup_screen.dart:76` — `stepLabel: 'Step 2 of 4 — Password'`
  - `lib/operator_web/screens/welcome_screen.dart:94` — `stepLabel: 'Step 1 of 4 — Welcome'`
  - `lib/operator_web/widgets/data_accuracy_explainer_card.dart:82` — `'instead — same outcome, different path.'`
  - `lib/operator_web/widgets/web_app_shell.dart:236` — `'Sign out — ends this browser session and returns '`
  - `lib/operator_web/widgets/vendor_lifecycle_notify_me_dialog.dart:226` — `"access is pending partnership clearance — we'll email "`
  - `lib/operator_web/screens/schedule_screen.dart:256` — `"Week of $range — $locationName's locked plan"`
  - `lib/operator_web/widgets/polling_tier_status_card.dart:399` — `"awareness during dinner rush — would Premium fit?"`
- Admin surfaces also use em-dashes (e.g. `audit_log_admin_screen.dart:305` — `'e.g. "Support ticket #4821 — verifying password change history"'`).

**Risk:** Either (a) the 11W.5 regression test is over-strict (em-dashes are fine in operator-facing copy generally), or (b) the broader codebase has been quietly violating the convention. Either way, the principle is ambiguous.

**Suggested action:** Either (a) broaden the test to cover all operator-facing strings in operator-web (forcing a sweep), (b) drop the test as an over-fit guardrail, or (c) document the carve-out: "em-dashes acceptable for stepLabel formatting / em-dash in sentence flow, but never in error messages / button labels." Out of scope to decide here.

### F-OW-4 (P3, NIT) — "View payload" / "Hide payload" copy in audit log row

**Surface:** `lib/operator_web/widgets/audit_log_row.dart:62`

**Evidence:** Button copy reads `'View payload'` / `'Hide payload'`. "Payload" is engineering jargon (HTTP / API term). Operators reading their own audit ledger may not recognize the term.

**Risk:** Minor — audit log is a power-user surface. UX writing standard (`project_ux_writing_standard.md`) says "*plain English; no engineering jargon*."

**Suggested action:** Consider `'Show details'` / `'Hide details'` or `'Show what changed'` / `'Hide what changed'`. Out of scope for this audit to decide the exact copy.

---

## Aggregate observations

### A1 — Inheritance Tree consumer compliance is healthy

The shared `lib/widgets/inheritance_tree.dart` widget (L_A1, VISUALIZATION-not-selector) has four consumers in the wave:

- `lib/operator_web/screens/hierarchy_screen.dart:425, :500` — wraps `InheritanceTree` inside `_OperatorWebHierarchyInheritanceTree` (visualization, with tap-to-mutate handlers that drive separate dialog flows; the tree itself is not the selector — the dialog is).
- `lib/admin/screens/audit_log_admin_screen.dart:228` — renders `InheritanceTree` PLUS a paired dropdown scope picker. The dropdown is the selector; tree taps drive the dropdown (compliant per the widget's own contract: tap callback is "tap region," not "selector").
- `lib/admin/screens/roles_hierarchy_sessions_admin_screen.dart:1428` — uses `InheritanceTree` for hierarchy panel visualization; mutate flows go through dedicated dialogs.

The widget's contract (line 1-25 of `inheritance_tree.dart`) is honored: every consumer treats the tree as visualization + an optional tap region that drives a separate selector or affordance, not as the selector itself.

**No findings here.**

### A2 — Demo-mode reader posture is clean

- Zero `kDemoMode` references in `lib/operator_web/` source (only test files / docs).
- Admin-side `kDemoMode` references are exclusively in comments + gateway-selection sites (`admin_routes.dart` picks demo vs HTTP gateway upstream, not in reader paths).
- No new reader-side `kDemoMode` branches landed in the wave.

**Verdict:** HP #2 (demo as writer-side switch) preserved. No 5th carve-out introduced.

### A3 — 2-console framing preserved

- Operator-web never produces `/admin/` paths. Explicit docstrings at `web_account_gateway.dart:29` and `web_business_timing_gateway.dart:25`.
- Operator-web `audit_log_screen.dart` does NOT expose a hierarchy filter — that surface is admin-only (B8) per the 2-console rule.
- Operator-web `audit_log_row.dart` only READS `adminReason` (line 102) — it never writes it. `adminReason` writes are admin-only.
- `members_screen.dart`, `roles_screen.dart`, `sessions_screen.dart` all operate within the operator's own tenant.
- No cross-operator queries surfaced from operator-web.
- Admin side: every admin screen sits behind `admin_auth_gate.dart` (Firebase admin claim) and uses HTTP gateways that resolve operator+location server-side.

**Verdict:** 2-console framing intact.

### A4 — C-10 admin parity copy applied

`lib/admin/admin_routes.dart` carries `'Admin only'` (10+ occurrences) and `'Read-only view'` (lines 387, 424) on the relevant nav tiles. The framing is consistent — F&F-only operations carry "Admin only," read-mostly tiles carry "Read-only view."

**Verdict:** PR #556 (C-10) framing preserved by subsequent wave PRs.

### A5 — Mobile read-mostly invariant preserved

- C-9 (PR #580) added inbox catalog rendering to `lib/screens/notifications_screen.dart` — no preference toggles, no write surface, just a presentation layer over arriving inbox rows.
- Spot grep for `Switch` / `Checkbox` / `togglePreference` in `lib/screens/notifications_screen.dart` returned no matches in preference-toggle context.
- PR #580 audit doc explicitly confirms: "*mobile preference switches deliberately absent (mobile read-only).*"

**Verdict:** C-Mobile product rule (read-mostly) preserved.

### A6 — UX writing standard spot-check (C-7 / B9.3 adaptive 2FA labels)

The four MFA card primary button labels in `lib/operator_web/account/mfa_card_controller.dart`:

- `:315` — `'Turn on 2FA'`
- `:330` — `'Manage methods'`
- `:344` — `'Cancel removal'`
- `:358` — `'Turn off 2FA'`

Paired badges read `'MFA: Not enrolled'` / `'MFA: Enrolled'` / `'MFA: Removal requested'` / `'MFA: Ready to turn off'`. Body copy at `:312-314`, `:341-343`, `:355-357` is plain-English training tone ("*so signing in requires your password and a one-time code from your authenticator app.*").

**Verdict:** UX writing standard upheld on the C-7 / B9.3 adaptive labels.

### A7 — Settings notifications (C-8) HP #11 carve-out is a positive exemplar

`lib/operator_web/screens/settings_notifications_screen.dart:38-42`:

> *Hierarchy carve-out (CLAUDE.md HP #11): notification preferences are per-(operator, user, event, channel), not hierarchy-scoped. This is the same carve-out the My Account screen relies on - it's a personal preference surface, not an org-config surface. Documented inline so future audit passes don't flag it as missing inheritance.*

This pattern (inline `HP #11` rationale block) is the model F-OW-2 recommends extending to `schedule_screen.dart` and `wage_authority_screen.dart`.

### A8 — Metric Honesty Doctrine compliance (Audit log + Benchmarks + Settings notifications)

- `audit_log_screen.dart` carries chain-anchor health hydration (`:184-199`) — surfaces transient-error vs degraded state honestly. No phantom counts.
- `settings_notifications_screen.dart` carries three explicit state badges (Available / Coming soon / Backend-only) per `_kEventState` map (`:88-95`). The wave deep audit (`wave_completion_deep_audit_2026_05_13.md:352-360`) flagged the fallback-default-to-`available` as a P2 honesty leak — this is a real concern but already tracked.
- `health_admin_screen.dart` is the A6.1 metric-honest rewrite: `_metricDisplayValue` returns `'No value yet'` for null/blank, `_metricRemediation` exhausts severities. Verified by the wave deep audit.
- No B6 "Benchmarks" screen exists in operator-web or admin (the only "benchmark" code lives in `lib/domain/`, `lib/services/`, `lib/models/`). The task brief's "B6 Benchmarks screen" appears to be a forward reference; no surface needs metric-honesty review yet.

**Verdict:** Metric Honesty compliance on the wave-touched surfaces is good. C-8 fallback honesty is a tracked P2 (per the deep audit) — no new finding here.

---

## Coverage gaps

### CG-1 — operator-web file-size ceiling has no codified anchor

The 1,665 LoC ceiling is anchored *only* in a PR audit doc (PR #624). It's not in `CLAUDE.md`, `docs/contracts/`, or any lint. Future agents will not see it unless they read PR #624. Recommendation: codify in `docs/contracts/operator_web_file_size_ceiling.md` OR add a lint at `tool/operator_web_file_size_lint.dart` mirroring `tool/advisor_proxy_size_lint.dart`. Out of scope for this audit to implement.

### CG-2 — No HP #11 lint / discoverability tool

Every wave-new operator-web surface that *isn't* hierarchy-scoped relies on either an inline comment block or an audit pass to detect compliance. There's no automated "does this surface display the (scope, source, value) triple?" check. The existence of the positive exemplars (`business_setup_screen.dart`, `business_timing_editor_screen.dart`, `settings_notifications_screen.dart`, `data_accuracy_screen.dart`, `admin_timing_setup_screen.dart`, `audit_log_admin_screen.dart`) and the gap on `schedule_screen.dart` + `wage_authority_screen.dart` suggests the doctrine is enforced by reviewer awareness only.

### CG-3 — Em-dash regression is narrow (covers 4 files)

`test/operator_web/screens/audit_log_screen_test.dart` covers 4 files. The principle (if it IS a principle) should either expand or be retired. See F-OW-3.

### CG-4 — Admin file-size discipline is undocumented

Top three admin screens (4894 / 2795 / 2670 LoC) have no codified ceiling. Operator-web has the 1,665 anchor (uncodified); admin has nothing. If admin screens proliferate at similar rates, the same audit-deferral-loop will eventually hit admin.

### CG-5 — Two-console boundary lint absence

The 2-console framing (operator-web own-operator-only, admin cross-operator) relies on `webProxyClient` paths never starting with `/admin/`. There's no lint or test that asserts this. Today's compliance is reviewer-enforced.

---

## Authority anchors

**Primary contracts and conventions:**

- `CLAUDE.md` § Hard Promises #2 (Demo Mode), #11 (Hierarchy-scoped settings)
- `~/.claude/projects/.../memory/project_two_console_framing.md` — F&F Ops Console vs Operator Web Console product split
- `~/.claude/projects/.../memory/project_ux_writing_standard.md` — operator-facing copy reads as training
- `~/.claude/projects/.../memory/project_metric_honesty_doctrine.md` — state + provenance on every metric

**In-repo wave anchors:**

- `docs/archive/_audits/post_codex_wave_2026-05-13/pr_624_b8_audit_log_hierarchy_filter_audit.md:21` — operator-web 1,665 LoC ceiling anchor
- `docs/archive/_audits/post_codex_wave_2026-05-13/pr_580_c_9_mobile_inbox_catalog_audit.md` — C-9 mobile read-only confirmation
- `docs/archive/_audits/post_codex_wave_2026-05-13/pr_556_c10_admin_parity_copy_audit.md` — C-10 "Admin only" / "Read-only view" framing
- `docs/archive/_audits/post_codex_wave_2026-05-13/pr_579_c_3_sign_in_security_to_my_account_audit.md` — C-3 fold-in deletion
- `docs/archive/_audits/post_codex_wave_2026-05-13/pr_568_b9_3_adaptive_2fa_card_audit.md` — B9.3 adaptive labels
- `docs/archive/_audits/post_codex_wave_2026-05-13/pr_481_retroactive_audit.md` — operator_location admin HP #11 retroactive fix
- `docs/_audits/post_codex_wave/wave_completion_deep_audit_2026_05_13.md` — orchestrator's prior 21-slice retrospective (overlapping P1/P2 already tracked: B9.2 clock skew, B11.1 idempotency, C-8 fallback)

**Code anchors for the findings:**

- F-OW-1: `lib/operator_web/screens/my_account_screen.dart` (LoC 2,051)
- F-OW-2: `lib/operator_web/screens/schedule_screen.dart` + `lib/operator_web/screens/wage_authority_screen.dart` (no HP #11 anchor)
- F-OW-3: `test/operator_web/screens/audit_log_screen_test.dart:383-425` + 45 operator-web files containing em-dashes
- F-OW-4: `lib/operator_web/widgets/audit_log_row.dart:62`

**Positive exemplars for HP #11 inheritance triple rendering:**

- `lib/operator_web/screens/business_setup_screen.dart:376-401` — `_InheritanceCard` showing inheritance chain
- `lib/operator_web/screens/business_setup_screen.dart:403-430` — `_EffectiveTimingCard`
- `lib/operator_web/screens/settings_notifications_screen.dart:38-42` — inline HP #11 carve-out doctrine
- `lib/admin/screens/admin_timing_setup_screen.dart:170-200` — "Selected scope" / "Timing source" / "Covered locations" / "Timezone" stack
- `lib/admin/screens/audit_log_admin_screen.dart:226-235` — `InheritanceTree` + paired dropdown selector
- `lib/admin/models/admin_hierarchy_settings_scope_policy.dart` — programmatic effective-value / value-state / allowed-actions decorator

**Inheritance Tree consumer compliance anchors:**

- `lib/widgets/inheritance_tree.dart:1-25` — VISUALIZATION-not-selector contract
- `lib/operator_web/screens/hierarchy_screen.dart:500` — consumer
- `lib/admin/screens/audit_log_admin_screen.dart:228` — consumer
- `lib/admin/screens/roles_hierarchy_sessions_admin_screen.dart:1428` — consumer

**Two-console framing anchors:**

- `lib/operator_web/services/web_account_gateway.dart:29` — operator-web never produces `/admin/` paths
- `lib/operator_web/services/web_business_timing_gateway.dart:25` — same posture for timing gateway
- `lib/admin/admin_auth_gate.dart` — admin-side Firebase admin claim gate

**Demo posture anchors:**

- `lib/admin/screens/audit_log_admin_screen.dart:14` — "*No `kDemoMode` carve-out on the reader path*"
- `lib/admin/services/audit_log_admin_gateway.dart:11` — "*No client-side `kDemoMode` carve-out*"
- `CLAUDE.md` § Demo Mode — 4 documented reader-side carve-outs, no 5th added in the wave

---

**End of audit.**
