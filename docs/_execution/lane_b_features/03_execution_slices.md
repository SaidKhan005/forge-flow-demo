# 03 — Execution Slices (Lane B — Features)

Status: planning draft, 2026-05-12.
Total slices: 13 across B1–B11 (some sub-lanes are bundled, some split).
Risk legend: 🟢 low / 🟡 medium / 🔴 high. Size legend: S = ≤1 day, M = 2-4 days,
L = 5+ days.

## Sequencing Overview

Three serial gates and three parallel families.

```
Gate 1 (must land before anything UI-facing):
  L_A1 — Inheritance Tree component (Lane A)
  L_A2 — Descendant-set cache utility (Lane A)
  L_A3 — Expand-contract migration discipline + audit-chain UPDATE lint (Lane A)

Gate 2 (must land before deep-link work):
  B11.1 — handoff_codes table + endpoints
  B11.2 — RFC 9470 challenge on sensitive routes

Gate 3 (must land before admin catalog editor UI):
  B10.1 — vendor_applicability schema + repository
  B2.1  — default_role_catalog_versions schema + repository

Parallel family P-A (Trust + Account Control — per addendum C1):
  B3, B4, B5, B9 — runnable concurrently after Gates land

Parallel family P-B (Hierarchy reads):
  B8, B6 — runnable after L_A1 + L_A2

Parallel family P-C (Polish + bug fixes):
  B1.a (inheritance notice propagation), B1.b (audit actor fix), B7.a (invite dialog bug)
```

## Slice Table

### B1.a — Inheritance notice propagation to Data Accuracy + Polling

| Field | Value |
|---|---|
| Scope | Apply PR #485's `admin_timing_scope_inheritance_notice` pattern to Data Accuracy + Polling tiles when business/org_unit scope picks a single covered location. |
| Files | `lib/admin/screens/per_location_data_accuracy_screen.dart`, `lib/admin/screens/polling_and_pricing_admin_screen.dart`, possibly `lib/admin/widgets/admin_scope_pane.dart` if a shared notice widget is extracted |
| Depends on | None (closure baseline). Reuses the existing notice key. |
| Risk | 🟢 |
| Size | S |

### B1.b — Admin audit actor fix (operator-location fan-out)

| Field | Value |
|---|---|
| Scope | Flip `actorKind: 'user'` to `'forge_admin'` at `tool/advisor_proxy/proxy_bootstrap.dart:3640` for the operator-location admin audit fan-out. Add a regression test that asserts the audit row's `actor_kind = 'forge_admin'`. |
| Files | `tool/advisor_proxy/proxy_bootstrap.dart` (line 3640 region), `test/advisor_proxy_test.dart` (or new targeted test) |
| Depends on | Audit chain `UPDATE` lint (L_A3) — confirm this isn't an audit_logs UPDATE (it's a write-time honesty fix; new rows only). |
| Risk | 🟡 — touches audit attribution. |
| Size | S |

### B2.1 — Default Role catalog schema + publish endpoint

| Field | Value |
|---|---|
| Scope | Add `default_role_catalog_versions` table; add `operators.default_role_catalog_version_id` pointer column (NULL = follow latest); add `POST /v1/admin/auth/role-catalogs/publish` and `GET /v1/admin/auth/role-catalogs` admin routes. Audit log entry on publish with SHA-256 + blast-radius count. Pull-time resolver returns the resolved catalog payload. |
| Files | `db/migrations/<ts>_default_role_catalog_versions.sql` (new); `lib/infrastructure/persistence/postgres/repositories/default_role_catalog_versions_repository.dart` (new); `tool/advisor_proxy/advisor_proxy.dart` (add route constants + handler); `lib/admin/services/default_role_catalog_admin_gateway.dart` (new); `lib/infrastructure/persistence/postgres/repositories/roles_repository.dart` (extend resolver). |
| Depends on | Gate 3. |
| Risk | 🟡 — new schema, new admin route. Pull pattern means operator-side reads now resolve against the catalog version, so regress carefully. |
| Size | M |

### B2.2 — Default Role catalog admin editor surface

| Field | Value |
|---|---|
| Scope | Admin console "Default Roles" page. Lists catalog versions; selecting "Latest" shows the current payload. Editor supports add/remove/edit role within a draft → publish (creates new version). Blast-radius preview before publish ("Affecting 47 businesses, 312 locations, 1,403 active users"). F&F Admin banner + colour-coded chrome (R1 #2 Principle 1). Operator-side "Default" badge + "Updated by F&F on <date>" inline in role list. |
| Files | `lib/admin/screens/default_role_catalog_admin_screen.dart` (new); `lib/admin/screens/default_role_catalog_publish_dialog.dart` (new); operator-web role list — `lib/operator_web/screens/roles_screen.dart` (add badge + "Updated by F&F" annotation). |
| Depends on | B2.1. |
| Risk | 🟡 — global blast radius requires precise blast-radius math + double-confirm. |
| Size | M |

### B3 — Role-key hybrid identifier sweep

| Field | Value |
|---|---|
| Scope | Audit every role lookup site; for non-seeded roles, force lookups via `role_id` UUID. Admin/operator-web role mutation routes accept `role_id` only (read returns both `role_id` + `display_name`). Add test that renaming a custom role's display name does NOT trigger any grant migration. |
| Files | `lib/infrastructure/persistence/postgres/repositories/roles_repository.dart`, `lib/operator_web/services/web_team_roles_gateway.dart`, `lib/admin/services/roles_hierarchy_sessions_admin_gateway.dart`, `tool/advisor_proxy/advisor_proxy.dart` (admin/team roles routes), `lib/auth/role_management_policy.dart`. |
| Depends on | None. |
| Risk | 🟡 — touches every role read/write path. |
| Size | M |

### B4 — Two-product taxonomy in role editor

| Field | Value |
|---|---|
| Scope | Refactor `custom_role_editor_screen.dart` into product-grouped two-tab editor (`Forge & Flow`, `Barrio`). Mirror in admin (`roles_hierarchy_sessions_admin_screen.dart`). Barrio tab renders "Coming soon" + disabled controls when operator's product plan does not include Barrio. Capture `product` field in `role_audit_log.change_payload`. |
| Files | `lib/operator_web/screens/custom_role_editor_screen.dart`, `lib/admin/screens/roles_hierarchy_sessions_admin_screen.dart`, possibly `lib/admin/widgets/role_permission_tree.dart` (new shared widget). |
| Depends on | None. Parallel with B3 (UI-only change; B3 is data-layer). |
| Risk | 🟢 |
| Size | M |

### B5 — Admin access-control + permission-key completeness sweep

| Field | Value |
|---|---|
| Scope | Sweep every admin route, confirm role gates match the matrix (super_admin/ff_support/operator-tier). Confirm every admin mutation passes `admin_reason`. **Flag (but do not amend)** the catalog gaps for `account.configure`, `business_timing.configure`, and any new keys needed by B2/B10. Open a follow-up slice for the catalog tri-mirror amendment. |
| Files | `tool/advisor_proxy/advisor_proxy.dart` (audit route guards); `lib/admin/services/*_admin_gateway.dart` (verify gates); `docs/_execution/lane_b_features/05.5_catalog_followup.md` (new — tri-mirror amendment proposal, hand off to catalog owner). |
| Depends on | None. |
| Risk | 🟢 — read-only audit + doc proposal. |
| Size | S |

### B6 — Benchmark override (operator-level, hierarchy-inherited)

| Field | Value |
|---|---|
| Scope | Add `benchmark_overrides` table with `(operator_id, scope_type, org_unit_id?, location_id?, metric_key, override_value, effective_from, effective_until?, created_by)`. Add `BenchmarkOverridesRepository` extending `OperatorScopedRepository<T>`. Add `GET/POST/PATCH/DELETE /v1/operator/benchmarks/overrides` routes (idempotency key on writes). Operator-web Settings → "Benchmarks" tile renders the override editor + Inheritance Tree showing resolved value per metric. Emit `benchmark.override.set` / `benchmark.override.clear` audit events. |
| Files | `db/migrations/<ts>_benchmark_overrides_hierarchy.sql` (new); `lib/infrastructure/persistence/postgres/repositories/benchmark_overrides_repository.dart` (new); `tool/advisor_proxy/advisor_proxy.dart` (route block); `lib/operator_web/screens/benchmarks_screen.dart` (new); `lib/services/baseline/*` (resolver hook). |
| Depends on | L_A1 (Inheritance Tree component), L_A2 (descendant-set cache), L_A3 (migration discipline). |
| Risk | 🟡 — new schema with hierarchy semantics; precedent in `forge_flow_polling_tier_scope_assignment` (`db/migrations/202605121200_admin_hierarchy_scoped_data_polling.sql`). |
| Size | L |

### B7.a — Invite dialog hierarchy-scope bug fix

| Field | Value |
|---|---|
| Scope | Fix `lib/admin/screens/invite_member_admin_dialog.dart:50-70,108-220`: make `primaryLocationId` nullable when `scopeType != 'location'`, or route through the scope picker so `operator_wide` / `org_unit` invites emit clean payloads. Surface Cancel CTA per row (R1 #11 — Cancel button visible, plain-English modal, 410 Gone on expired link, Undo toast 10s). Add invite.cancel audit event if missing. Resend uses same SendGrid template (`operator_admin_invite`). |
| Files | `lib/admin/screens/invite_member_admin_dialog.dart`, `lib/admin/services/members_admin_gateway.dart`, `lib/operator_web/screens/members_screen.dart` (operator parity), `lib/operator_web/services/web_team_members_gateway.dart`. |
| Depends on | None. |
| Risk | 🟡 — touches invite write path; precedent already supports the payload shapes (schema is correct). |
| Size | M |

### B8 — Audit log hierarchy filter

| Field | Value |
|---|---|
| Scope | Add `?scope_type=…&org_unit_id=…&location_id=…&from=…&to=…&actor_user_id=…&action=…` filter params on `/v1/admin/auth/audit-log`. Repository method `listByHierarchy(operatorId, scopeType, orgUnitId?, locationId?, range)` builds the ltree-bounded predicate using `locations.org_unit_path <@ $org_unit_path::ltree`. Descendant-set cache utility (Lane A) memoizes per (operator_id, org_unit_id). Build the admin audit log page; consume Inheritance Tree component for scope picker. Plain-English action labels in operator-web (mirroring `team.audit_log.view`). Perf probe `audit_log_hierarchy_filter_p95_ms` per `(operator_id, location_count)` bucket. |
| Files | `tool/advisor_proxy/advisor_proxy.dart` (audit-log handler region), `lib/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart` (new or extended), `lib/admin/screens/audit_log_admin_screen.dart` (new), `lib/operator_web/screens/audit_log_screen.dart` (verify uses the new filter), `tool/pressure/p4_*.dart` (perf probe). |
| Depends on | L_A1 (Inheritance Tree), L_A2 (descendant-set cache). |
| Risk | 🟡 — read-side join only; no audit_logs writes. Lint by L_A3 enforces. |
| Size | M |

### B9.1 — `/sign-in-security` 301 redirect

| Field | Value |
|---|---|
| Scope | Add 301 redirect handler for `/operator-web/sign-in-security` and admin equivalent → `/my-account#security`. Test inbound URL with query params + fragment is preserved. Email-template URL sweep is Lane C. |
| Files | `lib/operator_web/router/operator_web_router.dart`, `lib/admin/admin_routes.dart`. |
| Depends on | None. |
| Risk | 🟢 |
| Size | S |

### B9.2 — My Account consolidation + Active Sessions card

| Field | Value |
|---|---|
| Scope | Move Active Sessions section from `lib/screens/settings/settings_active_sessions_section.dart` into `MyAccountScreen` as a fourth top-level card. Add per-session "This device" annotation. Add "Sign out all other sessions" CTA gated by step-up. Audit-log link at bottom of each card (Profile / Security / MFA / Active Sessions). |
| Files | `lib/operator_web/screens/my_account_screen.dart`, `lib/operator_web/account/operator_web_account_actions.dart`, `lib/operator_web/services/web_account_gateway.dart`. |
| Depends on | B9.1 lands first (route alignment). |
| Risk | 🟡 — touches session management; uses existing proxy routes only. |
| Size | M |

### B9.3 — Adaptive 2FA button (4 states)

| Field | Value |
|---|---|
| Scope | Implement `MfaCardController` state machine: NotEnrolled → Enrolled → RemovalRequested(24h countdown) → Removable. Server-authoritative grace timer via the existing `mfa_factor_removal_requests` table. Cross-device sync. Plain-English copy on each state ("We wait 24 hours before turning off 2FA…"). Step-up required on Request-removal AND on Cancel. Wired into My Account MFA card. |
| Files | `lib/operator_web/screens/my_account_screen.dart` (MFA section), new `lib/operator_web/account/mfa_card_controller.dart`, possibly `lib/services/mfa/mfa_removal_service.dart` (verify the 24h grace logic matches). |
| Depends on | B9.2 (My Account consolidation). B11 (RFC 9470 step-up) — gracefully fall back to existing fresh-MFA listener if B11 lands after. |
| Risk | 🟡 — state machine + cross-device timing; existing `mfa_factor_removal_requests` data model already supports it. |
| Size | M |

### B10.1 — `vendor_applicability` table + repository + admin/operator routes

| Field | Value |
|---|---|
| Scope | Add `vendor_applicability` migration (per addendum A6 + r2 Topic 5). INSERT-only writes — "ending" a row sets `effective_until`. JSONB validator per `setting_kind`. RLS via `app_current_operator()` wrapper (operator_id nullable for F&F-admin defaults). Admin routes `GET/POST/PATCH /v1/admin/vendor-applicability` (super_admin gated). Operator routes `GET /v1/operator/vendor-applicability?setting_kind=...`. Audit events `vendor_applicability.upsert` / `.end`. |
| Files | `db/migrations/<ts>_vendor_applicability.sql` (new); `lib/infrastructure/persistence/postgres/repositories/vendor_applicability_repository.dart` (new); `lib/services/settings/applicability_metadata_schemas.dart` (new JSON validator); `tool/advisor_proxy/advisor_proxy.dart` (route block); `lib/admin/services/vendor_applicability_admin_gateway.dart` (new); `lib/operator_web/services/web_vendor_applicability_gateway.dart` (new). |
| Depends on | Gate 3 (precedes admin editor surface). L_A3 (expand-contract migration discipline). |
| Risk | 🟡 — new schema; reuse temporal-row pattern from `forge_flow_polling_tier_assignment`. |
| Size | M |

### B10.2 — Vendor applicability admin editor + operator-web wage authority binding

| Field | Value |
|---|---|
| Scope | Admin "Vendor Applicability" page. Tabs per setting_kind (`wage`, `covers`, `polling`). Vendor table with toggle, effective dates, metadata JSON. Plain-English copy ("Which vendors can act as the wage source?"). Operator-web Data Accuracy wage authority picker now reads `vendor_applicability` filtered by `setting_kind = 'wage' AND enabled = true AND effective_until IS NULL`. |
| Files | `lib/admin/screens/vendor_applicability_admin_screen.dart` (new); `lib/screens/settings/settings_wage_authority_section.dart` (read from `vendor_applicability`); `lib/admin/screens/per_location_data_accuracy_screen.dart` (covers source). |
| Depends on | B10.1. |
| Risk | 🟢 |
| Size | M |

### B11.1 — `handoff_codes` table + endpoints

| Field | Value |
|---|---|
| Scope | Add `handoff_codes (code text pk, user_id uuid, operator_id uuid, target_path text, expires_at timestamptz, consumed_at timestamptz null, source_device_fingerprint text, created_at timestamptz)`. 60-second TTL. Reaper for expired rows. Routes `POST /v1/auth/handoff/codes` (mobile mints code) + `POST /v1/auth/handoff/redeem` (web redeems atomic UPDATE … RETURNING; 410 on replay; 403 on wrong operator). Per-user rate limit 10/hour via existing proxy idempotency/rate-limit layer. Audit events `auth.handoff.code_created` and `auth.handoff.redeemed`. |
| Files | `db/migrations/<ts>_auth_handoff_codes.sql` (new); `lib/infrastructure/persistence/postgres/repositories/handoff_codes_repository.dart` (new); `tool/advisor_proxy/advisor_proxy.dart` (routes); `tool/advisor_proxy/auth_handoff_routes.dart` (new, decomposed in line with Lane A's proxy decomposition discipline); mobile deep-link emitter — `lib/services/auth/handoff_code_client.dart` (new); web client redeem — `lib/operator_web/auth/handoff_redeem.dart` (new). |
| Depends on | L_A3 (expand-contract). Gate 2 precedes B9.3 / B11.2 / mobile deep-link rewiring. |
| Risk | 🔴 — auth-critical, schema-touching, proxy-touching. Per CLAUDE.md "Auth-critical, RLS-touching, schema-touching, and proxy-touching slices require explicit operator approval before merge regardless of audit verdict." |
| Size | M |

### B11.2 — RFC 9470 step-up challenge on sensitive routes

| Field | Value |
|---|---|
| Scope | Identify the sensitive route list — account edits (`PATCH /v1/operator/account`, password change, MFA enroll), role mutations (POST/PATCH/DELETE on `/v1/admin/auth/roles*`, `/v1/auth/team/roles*`), billing (Phase 11A.2 pricing routes), and vendor applicability edits (B10). On each, when caller's `auth_time` is older than 5min, return 401 with `WWW-Authenticate: Bearer error="insufficient_user_authentication", acr_values="urn:mfa", max_age=300`. Web client and mobile client read the challenge, surface step-up MFA, retry. Adapt the existing `lib/auth/fresh_mfa_resolver.dart` + `mfa_freshness_redirect_listener.dart` to consume the standard header. |
| Files | `tool/advisor_proxy/advisor_proxy.dart` (challenge emitter), `lib/auth/fresh_mfa_resolver.dart`, `lib/auth/mfa_freshness_redirect_listener.dart`, `lib/operator_web/auth/step_up_challenge_handler.dart` (new). |
| Depends on | B11.1. |
| Risk | 🔴 — auth-critical, proxy-touching. Affects every sensitive route caller. |
| Size | M |

---

## Lane A prerequisites Lane B depends on (sequenced separately)

These do not live in Lane B's directory but are listed here so Lane B's slice
graph is honest about its waits.

| Prereq | What it is | Why Lane B waits |
|---|---|---|
| L_A1 — Inheritance Tree component | Shared widget (addendum C2) that renders Business → Org Unit → Location with effective-value annotation. | B6 + B8 consume it. Codex's scope pane is the *selector*; this is the *visualization*. |
| L_A2 — Descendant-set cache utility | Per-(operator_id, org_unit_id) → location_id[] cache; invalidate on hierarchy edit. | B8 + B6 hierarchy resolvers. |
| L_A3 — Expand-contract migration lint | `tool/migration_drift_scanner.dart --require-expand-contract` + audit-chain UPDATE allowlist. | Every new B migration runs it. |
| L_A4 — Proxy decomposition seam | Per-feature route file pattern (the `*_routes.dart` shape `audit_chain_anchors_routes.dart` already follows). | B11's `auth_handoff_routes.dart` follows this pattern. |

If Lane A delivers any of these later than Gate 1, B slices that depend on them
hold. Lane B keeps gate-1-independent slices (B1, B3, B4, B5, B7, B9.1, B2.1,
B11.1, B10.1) moving in parallel.

---

## Risk and Approval Notes

- **Operator approval required (CLAUDE.md "agent-led slices"):** B11.1, B11.2 (auth-critical + schema + proxy). B2.1 (proxy-touching + role catalog → blast radius). B10.1 (schema-touching + RLS). B6 (schema-touching).
- **Hash-chain integrity:** B1.b touches *new* audit row writes (the `actor_kind` flip is forward-only). B8 is read-only over audit_logs. No B slice mutates existing audit_logs rows.
- **Frozen-catalog respect:** No B slice writes to `lib/auth/permission_keys.dart`. B5 flags gaps; the catalog tri-mirror amendment is a separate slice owned by the catalog owner.
- **Hierarchy-everywhere (HP #11):** Every settings/access/audit surface in this lane uses the canonical scope pane + Inheritance Tree component. New carve-outs (My Account user-scope, Default Role catalog global-scope) are documented in `01_product_rule_and_ia.md`.
- **No JWT-in-URL (addendum A1):** B11 replaces the original decision #5. Mobile deep-link emitter, web redeem flow, and the RFC 9470 step-up all reference the redemption-code endpoint.
- **No demo-mode reader-branch (HP #2):** B slices reuse demo data via existing `MockReplayDataSourceProvider`. New schema (handoff_codes, vendor_applicability, benchmark_overrides, default_role_catalog_versions) is filled at demo seed time using the same DAOs production uses.

---

## Sizing Roll-Up

| Family | Slices | Total size |
|---|---|---|
| Polish + bug fixes (B1.a/b, B7.a) | 3 | ~M |
| Default Role catalog (B2.1/2) | 2 | M+M = L |
| Role hygiene (B3, B4) | 2 | M+M = L |
| Admin access control sweep (B5) | 1 | S |
| Hierarchy reads (B6, B8) | 2 | L+M |
| My Account consolidation (B9.1/2/3) | 3 | S+M+M = L |
| Vendor applicability (B10.1/2) | 2 | M+M = L |
| Handoff + step-up (B11.1/2) | 2 | M+M = L |

**Lane B total: ~7-9 engineer-weeks** including review cycles, assuming Lane A
gates land on schedule. Several P-A and P-C slices can ship in parallel
worktrees per `CLAUDE.md` agent-led discipline.
