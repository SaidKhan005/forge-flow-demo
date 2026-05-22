# Admin ↔ Operator-Web — Shared-Seam Inheritance Audit

**Date:** 2026-05-22
**Purpose:** Pre-planning audit for the Admin→Operator UX-alignment work. Before we write the build plan, pin down exactly what the admin console must **inherit** from operator-web's shared seams — functionality, rules, and UX — and what admin-only behavior must be **preserved**. Feeds the alignment road map (one scope picker + same menu reach + same names + demo banner + shared frame/widgets/chrome).
**Method:** 3 parallel read-only agents (operator-web surfaces, admin counterparts, shared layer + binding rules), whole-file reads, file:line cited. No code modified. All load-bearing artifacts verified to exist.
**Scope:** `lib/operator_web/**`, `lib/admin/**`, shared `lib/{theme,widgets,domain,services,auth,integrations}/**`, governing `CLAUDE.md` + contracts + `docs/_audits/cross_surface_parity_v1/`.

---

## 0. Headline

The two consoles already share **more than the road map assumes**, and that is good news: the inheritance work is mostly **adopting widgets and rules that already exist**, not building new behavior.

- **Shared today, wholesale:** the design tokens, the vendor-connections widget, the auth command/result models, the permission catalog + role validator, the permission-explainer view, the role permission picker, the inheritance-tree widget, the notification catalog, the data-accuracy/timing domain models + resolvers, and the canonical parity contract.
- **Forked at the chrome layer only:** admin re-implements the **shell / card / button / dialog / scope-notice** family instead of using operator-web's. This is the visible UX divergence and the bulk of the work.
- **Real rule gaps:** admin's hierarchy-scope notice is a degraded message box (HP#11), admin gates on role-sets not the `PermissionKeys` catalog, and admin has no demo-data tell.
- **Critical constraint:** parity is currently held by **duplication** (mirrored copy constants, mirrored enums, mirrored gateway interfaces) enforced by contract + lint, not by the compiler. Hardening it into real shared code touches auth/RLS/proxy seams and is **operator-approval-gated** per CLAUDE.md.

---

## 1. Shared seams today (admin must REUSE, not re-implement)

| Seam | Path | Status |
|---|---|---|
| Design tokens | `lib/theme/app_theme.dart` (AppColors/TextStyles/Radius/Spacing/Decoration) | SHARED (admin imports in ~45 files) |
| Vendor-connections widget + gateway + models | `lib/integrations/ui/vendor_connections/vendor_connections_widget.dart` (+ gateway, models) | SHARED — both consoles mount it, host injects the gateway. **The proven template for everything else.** |
| Auth command/result models | `lib/services/auth/auth_operations_gateway.dart` (`Team*` commands/entries) | SHARED — both consoles' gateways speak these |
| Custom-role validator + `RoleScope` | `lib/services/auth/custom_role_validator.dart` (already carries `admin.*` view/write pairings) | SHARED type; **admin imports `RoleScope` but does NOT call `.validate()`** |
| Permission explainer | `lib/widgets/permission_explainer_view.dart` | SHARED — built explicitly to stop operator/admin drift |
| Role permission picker | `lib/widgets/role_permission_picker.dart` | SHARED widget; **admin hardcodes `RoleScope.business`, skips the coherence warnings** |
| Inheritance tree | `lib/widgets/inheritance_tree.dart` + `lib/domain/models/inheritance_tree_node.dart` | SHARED |
| Permission catalog + metadata | `lib/auth/permission_keys.dart`, `lib/auth/permission_key_metadata.dart` | SHARED |
| Notification catalog | `lib/domain/models/notification_event_catalog.dart` (+ admin hits the SAME `/v1/operator/notification-preferences` route) | SHARED |
| Data-accuracy / timing domain + resolvers | `lib/domain/models/data_accuracy_settings.dart`, `domain/services/service_period_definition_resolver.dart`, `domain/services/business_timing_profile_resolver.dart`, `services/business_timing/business_timing_profile_validator.dart` | SHARED models/resolvers (gateways forked) |
| Hierarchy pickers | `lib/operator_web/widgets/hierarchy_map_picker.dart`, `hierarchy_tree_picker.dart` | Admin already **cross-imports** these from operator-web — proof the operator→admin import direction is sanctioned |
| Idempotency keys on writes | both consoles' gateways | COMPLIANT (parity items G60/OW-G72/G70 closed) |
| Canonical parity contract | `docs/contracts/team_roles_hierarchy_console_parity_contract.md` | Binds Members/Roles/Hierarchy/Sessions/Audit/Security parity incl. admin-only asymmetries |

---

## 2. Crossover surfaces — shared seam vs fork

| Surface | Operator-web | Admin | Shared seam | Admin forks | Rules/UX admin MISSES |
|---|---|---|---|---|---|
| **Team members** | `members_screen.dart`, invite/edit dialogs | `members_admin_screen.dart`, `invite_member_admin_dialog.dart` | Auth command models; hierarchy pickers (cross-imported) | Gateway (contract-mandated, `dart:io`-free); page chrome; **`MembersValidationCopy` duplicates `InviteMemberDialogCopy` byte-for-byte** | Shared copy constants; operator shell widgets |
| **Roles & permissions** | `roles_screen.dart`, `custom_role_editor_screen.dart` | `roles_hierarchy_sessions_admin_screen.dart` | `custom_role_validator.dart`, `role_permission_picker.dart`, `permission_explainer_view.dart`, `inheritance_tree.dart`, permission catalog | Gateway; page chrome | **Calls `.validate()` for advisory warnings (admin skips it)**; `kCustomRoleEditorUnknownKeyMessage` |
| **Active sessions** | `sessions_screen.dart` | tab in `roles_hierarchy_sessions_admin_screen.dart` | Session models | Gateway; chrome | two-section gated layout; relative-time/geo/device helpers |
| **Audit log** | `audit_log_screen.dart`, `audit_log_row.dart` | `audit_log_admin_screen.dart`, `audited_support_actions_admin_screen.dart` | `inheritance_tree.dart`, actor-kind labels | Gateway; chrome | `AuditLogIntegrityBadge` (already mirrors admin health screen — unify), `audit_log_row.dart` |
| **Vendor integrations** | `vendor_connections_screen.dart` | `vendor_connections_admin_mount.dart` | **`VendorConnectionsWidget` (fully shared)** | only the host chrome wrapper | nothing — this is the model case |
| **Data accuracy / wage** | `data_accuracy_screen.dart`, `wage_authority/**`, `widgets/data_accuracy_*` | `per_location_data_accuracy_screen.dart`, `per_location_data_accuracy_table.dart` | domain models + resolvers + `wage_role_row_scope_resolver.dart` (HP#11) | Gateway; **forked table widget**; degraded scope notice | the presentation widgets (`data_accuracy_*`, `covers_*`, `blended_wage_*`, `_ScopeBadge`); structured scope notice |
| **Timing** | `business_timing_editor_screen.dart` (WRITE) | `admin_timing_setup_screen.dart` (READ-ONLY by design) | `business_timing_profile_validator.dart`, `business_timing_profile_resolver.dart` | Gateway; read-only posture | `service_period_editor.dart` + controller; (write affordances are intentionally absent — server-side super-admin repair) |
| **Notifications** | `settings_notifications_screen.dart` | `admin_notification_preferences_screen.dart` | `notification_event_catalog.dart`, SAME backend route | Gateway | role-gate row filtering (intentional: admin actor isn't an operator role → full catalog) |
| **My account** | `my_account_screen.dart` + dialogs | `my_account_admin_screen.dart` | self-routes via gateways | Gateway; chrome; **read-only MFA/sessions** (no admin mutation gateway yet) | `WebSecurityPasswordCopy`, `MfaCardController` state machine, login-history section; **`change_password_dialog.dart` uses a bare `Dialog`, not `OperatorWebDialog`** (fix on lift) |

---

## 3. Forked but should be shared (the alignment lift)

Lift these out of `lib/operator_web/` into a neutral shared layer (e.g. `lib/widgets/console/`) so admin inherits behavior + copy instead of forking. Ordered by impact.

1. **The operator widget kit (biggest visual win).** `operator_web_surface.dart` (`OperatorWebPanel`/`Banner`/`Dialog`/`DialogHeader`/`DateRangeDialog` + `showOperatorWebDialog`), `operator_web_screen_body.dart`, `operator_web_screen_header.dart`, `operator_web_section_heading.dart`, `operator_web_info_button.dart`. Retire admin's parallels: `admin_responsive_layout.dart` (AdminCard), `admin_button_styles.dart`, bare layouts.
2. **`HierarchyScopeNotice` (biggest rule win).** Operator-web's `lib/operator_web/widgets/hierarchy_scope_notice.dart` renders the real HP#11 triple (selected scope + inherited source + effective value + backend-only explainer). Admin's `lib/admin/widgets/admin_hierarchy_scope_notice.dart` is a free-text message box with none of those fields. Adopt the operator widget; retire the degraded one.
3. **Locked validation-copy constants.** `InviteMemberDialogCopy`, `EditMemberDialogCopy`, `WebSecurityPasswordCopy`, `kCustomRoleEditorUnknownKeyMessage`. Admin duplicates these byte-for-byte today. Move to contract-backed shared constants so the strings cannot drift.
4. **Data-accuracy / covers / wage presentation widgets.** `widgets/data_accuracy_*`, `covers_*`, `wage_source_toggle.dart`, `keyed_service_period_accuracy_card.dart`, `polling_tier_status_card.dart`, `wage_authority/blended_wage_*`, `_ScopeBadge` — pure presentation over already-shared models.
5. **Role-editor validator usage.** Have admin's role editor call `CustomRoleValidator.validate()` (it already imports `RoleScope`) so the coherence warnings surface in admin too.
6. **`service_period_editor.dart` + `ServicePeriodEditorController`** (timezone dropdown + GMT-label map).
7. **`AuditLogIntegrityBadge` + `audit_log_row.dart`** — the badge already mirrors the admin health screen; unify into one shared widget.
8. **`MfaCardController` / login-history section** — once an admin MFA/sessions mutation gateway exists.
9. **Shared error-envelope handling** (parity item G63) — operator-web gateways each invent their own codes; unify.

> **Note on gateways:** the per-surface gateway forks (`MembersAdminGateway` vs `WebTeamUsersGateway`, etc.) are **contract-mandated** — the web build must stay free of `dart:io`. "Share" here means extract a shared **interface + row models** both implement, NOT merge the gateways. Any such move is auth/RLS/proxy-touching → **operator approval required**.

---

## 4. Rules admin must inherit (with gap status)

| Rule (source) | Status | Note |
|---|---|---|
| HP#11 hierarchy-scoped settings: selected + inherited + effective triple (CLAUDE.md HP#11) | **GAP** | Timing fixed (#893/#906/#923, read-only-accurate). Structured notice widget not shared. Admin **Pricing still has zero scope chrome** (parity G43, open). |
| UX no-em-dash law (`tool/ux_em_dash_lint.dart`) | **COMPLIANT** | `kUxCopyRoots` already includes `lib/admin/screens`, `lib/admin/widgets`, `lib/admin/admin_routes.dart`. Minor: `lib/admin/services/**` + `lib/admin/models/**` are not lint-recursed (doctrine still binds copy there). |
| Idempotency keys on writes (CLAUDE.md Proxy & API) | **COMPLIANT** | Both consoles stable after G60/OW-G72/G70/G71. |
| Permission enforcement on frozen `PermissionKeys` (`lib/auth/permission_keys.dart`) | **GAP** | Admin gates on `roles.contains(roleSuperAdmin)` (~16 sites) + 4 bare `'super_admin'` literals; never consults the capability catalog. Parity G7/G8 (helper DRY'd via #885/#887; model still role-set). **Auth-gated.** |
| Error-envelope handling (CLAUDE.md Proxy & API) | **GAP** | Operator-web side (G63) not unified; no shared envelope contract. |
| Demo-data honesty tell (parity X-G70 / G72) | **GAP** | Operator-web has a persistent demo banner; admin has none in demo/share-preview. (The alignment road map's demo banner closes this.) |
| Metric Honesty Doctrine (state + provenance, `'—'` sentinel) | **SHARED GAP (both consoles)** | `MetricPill` + the `MetricState`/`MetricProvenance` triple are used by **neither** web console (mobile-only). Honest framing: this is NOT "inherit from operator" — it's net-new for both web consoles if we want it. Track separately, not in the alignment lift. |

---

## 5. Admin-only behavior to PRESERVE (must NOT be lost when aligning)

1. **`admin_reason` on every admin write** — and on audit-log **reads**. `forge_admin` mutations are uniquely reason-stamped.
2. **Two-layer gate:** `actorIsForgeAdmin` / `editingEnabled` (UI hides affordances + gateway throws `*ForbiddenException`). `super_admin` = edit, `ff_support` = read-only.
3. **MFA-fresh gates:** `admin.users.reset_mfa_factors`, `admin.users.erase_pii`, `admin.roles.edit_seeded`.
4. **Paired-approval / dual-control PII erasure** with 24h grace ticker — no operator-web equivalent.
5. **`actor_kind = 'forge_admin'`** audit marker on every admin write (vs `team_member` on operator-web).
6. **Cross-tenant scope:** explicit `operator_id`/`location_id` per call; `forge_admin` BYPASSRLS posture. (Operator-web clamps operator from the session JWT.)
7. **Admin-only actions:** `restoreSoftDeletedMember`, `overrideRoleGrant` (Members); platform provider-key rotation with one-time reveal (Integration / Connected services); default-role-catalog publish, `super_admin`-only.
8. **HP#11 cross-operator label** on admin My Account degrades to a single "Global / cross-operator" instead of the business/region/location triple — intentional.
9. **Read-only-by-design** surfaces: admin Timing (write = server-side super-admin repair) and admin My Account MFA/sessions (pending admin mutation gateways). Keep read-only until those gateways exist.

### Guardrails — leave as-is on purpose (not to-do)

- **The business-selection step stays.** Admin spans many businesses; operator has one. Keep the step — just make it the single top-bar picker from §6 W1, not three competing patterns.
- **Admin-only screens stay admin-only** (no operator twin): Launch controls, Knowledge base, AI Metrics, System health, Plans & limits, Vendor applicability, Support logs — plus **Connected services, Default roles, Polling setup** (correction from the original list: these have no operator twin either, so they are not renamed or merged into the per-business screens).
- **Wide / split-screen admin tables** for dense data may stay wider than operator's, as long as the surrounding frame (§6 V1) is consistent.

---

## 6. Consistency to-do (inherits the above)

**Visuals — shared widget layer (operator approval not required; pure UI):**
- V1. Lift the operator widget kit (§3.1) to `lib/widgets/console/`; point admin at it; retire `admin_button_styles.dart` / `admin_responsive_layout.dart` card. → one frame, card, button, dialog, banner.
- V2. Adopt operator's structured `HierarchyScopeNotice` (§3.2); retire `admin_hierarchy_scope_notice.dart`. → real HP#11 triple on admin scope-aware screens.
- V3. Match menu + top-bar chrome (operator light section headers, 96px header) — already shown in the mockup.

**Workflow / rules:**
- W1. One scope picker + same menu reach (flip `visibleInNav` in `admin_routes.dart`) + operator vocabulary — already designed in the mockup.
- W2. Add the demo-data banner (closes X-G70/G72).
- W3. Share the locked copy constants (§3.3) so admin stops duplicating validation strings.
- W4. Call `CustomRoleValidator.validate()` in admin's role editor (§3.5).
- W5. Adopt shared data-accuracy/covers/wage presentation widgets (§3.4).
- W6. (Auth-gated, sequence later) migrate admin gating from role-sets to `PermissionKeys`; unify error envelopes (§4 gaps).

**Preserve:** everything in §5 — bake these into the plan's acceptance checks so alignment never strips a gate.

---

## 7. Risks & gates

- **Parity-by-duplication is the current safety net.** Mirrored copy/enums/gateway interfaces are enforced by `team_roles_hierarchy_console_parity_contract.md` + `tool/permission_key_lint.dart`, not the compiler. Extracting shared code hardens this — but until extracted, any rename must update both sides.
- **Auth/RLS/proxy approval gate:** §3 gateway-interface extraction and §6 W6 (permission-key migration, error envelopes) touch auth/RLS/proxy seams → explicit operator approval per CLAUDE.md, same as any auth-critical slice.
- **Sequence:** do the pure-UI lifts (V1–V3, W1–W3, W5) first (no auth surface), then the validator/copy shares (W4, W3), then the auth-gated items (W6) last with approval.

**Cross-reference:** `docs/_audits/cross_surface_parity_v1/cross_surface_parity_audit_2026_05_16.md` (functional/security parity register; G7/G40/G43/G62/G63/G72/X-G70), `docs/contracts/team_roles_hierarchy_console_parity_contract.md` (binding parity spec), CLAUDE.md Hard Promise #11.
