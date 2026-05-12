# 02 — Plumbing Audit Matrix (Lane B — Features)

Status: planning draft, 2026-05-12.
Coverage: 14-lens deep pass across B1–B11. Citations are file:line as found at
worktree `nifty-clarke-d3ec25` HEAD. Findings call out contract gaps but
do NOT amend contracts.

## Scan Index

- `lib/admin/**` — admin console surfaces
- `lib/operator_web/**` — operator web surfaces (My Account, custom role editor)
- `lib/screens/account/**`, `lib/screens/auth/**` — mobile auth surfaces
- `lib/services/auth/**`, `lib/services/mfa/**` — auth/MFA orchestration
- `lib/auth/**` — frozen permission key catalog (read only; do not modify)
- `tool/advisor_proxy/**` — proxy routes
- `db/migrations/**` — schema (role/permission/auth_invites/audit_logs/locations
  /org_units)

---

## B1 — Hierarchy refinement (post-overhaul polish only)

Closure 2026-05-12 (`docs/_execution/admin_hierarchy_settings_overhaul/06_closure_evidence_2026-05-12.md`).
B1 is additive on top, NOT a redo.

| Lens | Code/doc checked | Finding | Required action |
|---|---|---|---|
| Lens 2 IA | `lib/admin/admin_routes.dart`, `lib/admin/admin_shell.dart` | "Business accounts" pivot live; 8 setup tiles render. | None — closure complete. |
| Lens 6 Auth/scope | `lib/admin/screens/operator_location_admin_screen.dart`, `lib/admin/screens/per_location_data_accuracy_screen.dart` | Per-(business, org_unit, location) tile scope intent threaded via `AdminHierarchyScopeIntent`. | Verify integrations tile still labels its location-only carve-out (closure noted "Vendor Connections" label per PR #467 / `018a6e07`). |
| Lens 9 UX | PR #485 `a2766824` — admin timing scope inheritance notice key `admin_timing_scope_inheritance_notice` rendered at business scope, suppressed at location scope | Verified in closure walkthrough (2026-05-12). | None for timing; **propagate the same inheritance-notice pattern to Data Accuracy + Polling tiles when business/org_unit scope picks a single covered location**. Slice B1.a. |
| Lens 11 Parity | Operator-web mirror (`lib/operator_web/screens/**`) | Closure flagged "cross-flavor parity — phase_11W.*". Hierarchy-scoped settings panes are admin-only at closure. | Operator-web "Settings" inheritance-display polish — Lane C (parity) owns the cross-surface push. Lane B carves out only the *admin-side* polish. |
| Lens 13 Audit | `tool/advisor_proxy/proxy_bootstrap.dart:3640` | Closure carries the drift observation: operator-location admin audit fan-out emits `actorKind: 'user'` → maps to `actor_kind = 'team_member'` instead of `'forge_admin'`. Carried in `docs/_audits/post_codex_wave/pr_490_audit.md`. | Lane B owns the targeted fix because audit-actor honesty intersects B8 audit filter. Slice B1.b — one-line flip with audit-rebake guarded against chain integrity. Lift onto `docs/POST_HARDENING_FOLLOWUPS.md` if not picked up. |
| Lens 9 UX (Inheritance Tree component) | Codex scope pane (`lib/admin/widgets/admin_scope_pane.dart` per closure trace) is the hierarchy *selector*. Inheritance *visualization* is not a shared widget yet. | Per addendum C2: "build one shared Inheritance Tree component as Lane A code-health prerequisite." | Lane A owns the component. Lane B consumes via slices B6 (benchmark override), B8 (audit filter), and any future inheritance display. **Sequence: B6/B8 wait on Lane A's component.** |

---

## B2 — Default Roles catalog (admin-editable, pull pattern)

| Lens | Code/doc checked | Finding | Required action |
|---|---|---|---|
| Lens 3 Data model | `db/migrations/202604250008_auth_schema_foundation.sql:103-130` (roles), `:914-1090` (seed 6 baseline roles) | `roles.is_seeded = true` + `is_editable = false` on `super_admin`/`ff_support`. Operator-scoped custom roles inherit `is_seeded = false`. **No catalog versioning table exists yet.** | Add migration `db/migrations/<ts>_default_role_catalog_versions.sql` with `default_role_catalog_versions (version_id uuid pk, version_label text unique, published_at, published_by uuid, payload jsonb, payload_sha256 text, changelog text)`. Pull-time resolution (addendum A2 + r2 Topic 6 schema sketch). |
| Lens 3 Data model | `db/migrations/202604250008_auth_schema_foundation.sql:917-1090` | Seeded grants insert directly into `role_permissions` — no version pointer. | Add `businesses.default_role_catalog_version_id uuid null references default_role_catalog_versions(version_id)`. NULL = follow latest. (Note: `businesses` table — verify exact table name; `operators` is the canonical entity in `db/migrations/202604250005_advisor_cloud_foundation.sql`.) |
| Lens 4 Repository | `lib/infrastructure/persistence/postgres/repositories/roles_repository.dart` | Today resolves roles by `operator_id` join only. | Extend resolver: when `operator_id` is set, resolve via current catalog version (pinned or latest) for `is_seeded` roles; pass through for custom roles. |
| Lens 5 Proxy route | `tool/advisor_proxy/advisor_proxy.dart:6979` (`adminAuthRolesPath = '/v1/admin/auth/roles'`) | Today serves a flat list. **No publish endpoint exists.** | Add `POST /v1/admin/auth/role-catalogs/publish` (super_admin only). Body: catalog payload. Stores SHA-256 + previous version id; emits audit row `default_role_catalog.publish` with `actor_kind = 'user'` (F&F admin) + blast-radius count. |
| Lens 6 Auth | `lib/auth/permission_keys.dart` (frozen) | `admin.roles.edit_seeded` exists (`docs/contracts/auth_permission_key_catalog.md:138`). | **Contract gap:** no specific key for `default_role_catalog.publish`. Decide: reuse `admin.roles.edit_seeded` (currently MFA-required) or add a new `admin.roles.catalog_publish`. Lane B's plan recommends reuse; if the catalog publish ends up surfaced as distinct from editing one role's seeded permissions, propose a new key in a follow-up. Flag for contract owner. |
| Lens 7 Lifecycle | n/a — catalog is append-only | Deprecation flow not modelled today. | Per r1 #2 + r2 Topic 6: add `deprecated_at` on `default_role_catalog_versions` payload entries (in JSONB shape) so removed permission keys appear `deprecated` for ≥1 release before drop. |
| Lens 13 Audit | `db/migrations/202604280005_phase_9_0sigma_f_audit_logs.sql` | Hash-chained `audit_logs` partitioned per (operator_id, chain_date). Publish event uses NULL operator_id (global event). | Add publish event payload schema documented at code site. Use `operator_id IS NULL` partial index pattern from `auth_events_audit_global_occurred_idx`. |

---

## B3 — Role-key hybrid identifier (UUID immutable, slug presentational)

| Lens | Code/doc checked | Finding | Required action |
|---|---|---|---|
| Lens 3 Data model | `db/migrations/202604250008_auth_schema_foundation.sql:103-130` | `roles.role_id` UUID already PK. `role_permissions.role_id`, `user_roles.role_id`, `auth_invites.role_id`, `role_audit_log.role_id` are all FKs by UUID. **`role_key` is a string slug, unique per (operator_id, role_key) and globally for seeded roles.** | **The hybrid model is already 80% in place at schema level.** B3's work is mostly code/UX hygiene, not migration. |
| Lens 4 Repository | `lib/infrastructure/persistence/postgres/repositories/roles_repository.dart`, `lib/operator_web/services/web_team_roles_gateway.dart` | Mixed usage — some lookups by `role_key` (seeded roles), some by `role_id` (custom). | Audit every lookup site; for non-seeded roles, lookups must go via `role_id`. Seeded-role lookups by slug stay because the six baseline slugs are part of the catalog. |
| Lens 5 Proxy route | `tool/advisor_proxy/advisor_proxy.dart` — admin roles routes | Some routes accept role identifier in body as `role_key`, others as `role_id`. | Standardize: every mutation route requires `role_id`. Read routes return both; clients display name + `role_id`. |
| Lens 6 Auth | `lib/auth/role_management_policy.dart` | Defines edit gates by slug. Should accept either. | After B3, internal calls use `role_id`; slug-based seeded role check stays for the six baseline. |
| Lens 9 UX | `lib/operator_web/screens/custom_role_editor_screen.dart`, `lib/admin/screens/roles_hierarchy_sessions_admin_screen.dart` | No UI ever asks for role key — name only. | Verify no debug screen leaks the slug into primary scan. Tooltip on "Show details" is fine. |
| Lens 13 Audit | `db/migrations/202604250008_auth_schema_foundation.sql:394+` (`role_audit_log.role_id`) | Audit log already references by UUID. | None — confirmed clean. |

---

## B4 — Two-product taxonomy in role editor

| Lens | Code/doc checked | Finding | Required action |
|---|---|---|---|
| Lens 3 Data model | `lib/auth/permission_keys.dart`, `docs/contracts/auth_permission_key_catalog.md` | Two product namespaces exist: `product.forgeflow.access`, `product.barrio.access`. `forgeflow.*` (20 keys), `barrio.*` (12 keys). Catalog already partitioned by product. | None at data layer. |
| Lens 9 UX | `lib/operator_web/screens/custom_role_editor_screen.dart` | Today renders permissions as a flat list (no product grouping). | Refactor into two sibling tabs `Forge & Flow` and `Barrio`. Within each tab, group by resource (Shift, Variance, Schedule, etc.). |
| Lens 9 UX | Admin parity — `lib/admin/screens/roles_hierarchy_sessions_admin_screen.dart` | Admin role editor may not yet exist as a first-class surface. Closure 2026-05-12 listed "People, access, and roles" tile under PR #468. | Verify admin surface has the same editor shape; if missing, ship the admin variant of the operator-web editor with the two-product tabs. |
| Lens 6 Auth | `lib/auth/permission_keys.dart:product.barrio.access` | Operators on F&F-only plan should not see Barrio tab content. | Plan flag — read `operator.product_plan` or equivalent. If absent today (likely), surface Barrio tab but render "Coming soon" + disable all controls. Real plan gating ships when Barrio unpauses. |
| Lens 13 Audit | `role_audit_log` | Permission selection changes audited via `change_payload`. | Capture `product` field in payload so audit reports filter by product. |

---

## B5 — Admin console access control + permission key completeness

| Lens | Code/doc checked | Finding | Required action |
|---|---|---|---|
| Lens 5 Proxy route | `tool/advisor_proxy/advisor_proxy.dart` admin routes (`/v1/admin/auth/*`, `/v1/admin/operators/*`, `/v1/admin/pricing/*`, `/v1/admin/data-accuracy/*`) | Each route declares its required role set (`kFfPricingAdminReadRoles`, etc.). | Sweep every admin route and confirm: (a) `super_admin` always passes; (b) `ff_support` matches the support read-only model; (c) operator-tier roles are rejected for global admin routes. |
| Lens 6 Auth | `docs/contracts/auth_permission_key_catalog.md:314+` ("Pending additions") | Three operator-web screens hand-type `account.configure` and `business_timing.configure` against namespaces NOT in the frozen catalog: `lib/screens/account_screen.dart`, `lib/screens/business_setup_screen.dart`, `lib/screens/business_timing_editor_screen.dart`. | **Contract gap.** Flag for the catalog tri-mirror change. Lane B does not amend `lib/auth/permission_keys.dart` (frozen). Surface as an outstanding catalog reconciliation slice (B5.gap) and queue for the next catalog amendment. |
| Lens 6 Auth | `lib/auth/permission_keys.dart` | `admin.users.reset_mfa_factors` (11A.14 addition) and `admin.audit_privacy.read` (9.0Σ.h2) are in catalog. `admin.roles.edit_seeded` requires MFA. | Reuse `admin.roles.edit_seeded` for catalog publish (see B2). |
| Lens 13 Audit | `db/migrations/202605131000_admin_audit_log_actor_reason_contract.sql` | Admin audit reason contract live. | Confirm every admin mutation includes `admin_reason`; sweep new B2/B10 endpoints for the same pattern. |

---

## B6 — Benchmark override (operator-level, with hierarchy inheritance)

| Lens | Code/doc checked | Finding | Required action |
|---|---|---|---|
| Lens 3 Data model | grep `baseline_override|baseline.override` across `db/migrations` | **No storage table exists** for operator-level benchmark overrides per metric. Permission key `forgeflow.baseline.override` (`lib/auth/permission_keys.dart:63`) exists; no schema. | Add migration `db/migrations/<ts>_benchmark_overrides_hierarchy.sql` with `benchmark_overrides (override_id uuid pk, operator_id uuid, scope_type text check in ('operator_wide','org_unit','location'), org_unit_id uuid null, location_id uuid null, metric_key text, override_value numeric, effective_from timestamptz, effective_until timestamptz null, created_by uuid)`. Lead-index with `operator_id`. RLS via `app_current_operator()` + `app_current_location()`. |
| Lens 4 Repository | `lib/services/baseline/*` (existing baseline tracker) | Currently surfaces target snapshot reads; no override write path. | New `BenchmarkOverridesRepository` extending `OperatorScopedRepository<T>`. Hierarchy resolver returns the lowest-configured scope value. |
| Lens 5 Proxy route | n/a | No `/v1/operator/benchmarks/overrides` exists. | Add `GET/POST/PATCH/DELETE /v1/operator/benchmarks/overrides`. Idempotency-Key on writes. `forgeflow.baseline.override` permission gate. |
| Lens 6 Auth | `lib/auth/permission_keys.dart:63` | `forgeflow.baseline.override` defined. | None at catalog. |
| Lens 9 UX | `lib/screens/baseline_manager_screen.dart` | Operator-mobile surface today. | Add a Settings → "Benchmarks" tile in operator-web (web is the edit surface; mobile stays read-only). Use Lane A's Inheritance Tree component to show resolved value. |
| Lens 13 Audit | `audit_logs` | No existing event. | Emit `benchmark.override.set` / `benchmark.override.clear`; include `(scope_type, target_id, metric_key, prev_value, new_value)`. |

---

## B7 — Invite flow audit

| Lens | Code/doc checked | Finding | Required action |
|---|---|---|---|
| Lens 3 Data model | `db/migrations/202604250008_auth_schema_foundation.sql:307-337`, `db/migrations/202604290101_phase_9_hierarchy_access_wiring.sql:150-203` | `auth_invites` carries `scope_type` ('operator_wide'/'org_unit'/'location') + `org_unit_id` nullable + `location_id` nullable. Check constraint enforces scope payload shape. | **Schema is correct — hierarchy already supported.** |
| Lens 9 UX | `lib/admin/screens/invite_member_admin_dialog.dart:50-70`, `:108-220` | `InviteMemberAdminDraft.primaryLocationId` is `final String` (required). At line 57, `scopeType = 'location'` default. At line 217, business/org_unit scope passes `scope.locationId ?? ''` — passing empty string into a required field. | **Bug.** The dialog assumes a location exists even for `operator_wide`/`org_unit` invites. Either (a) make `primaryLocationId` nullable when `scopeType != 'location'`, or (b) re-route the dialog through the existing scope picker and emit the right payload. Slice B7.a. |
| Lens 5 Proxy route | `tool/advisor_proxy/advisor_proxy.dart:6975-6987` | `/v1/admin/auth/invites` + `/v1/auth/team/invites` exist. | Verify both routes accept the hierarchy-scoped payload (the schema does); add tests that exercise all three `scope_type` values. |
| Lens 4 Email delivery | `lib/services/email/email_template_renderer.dart:87-89`, `tool/advisor_proxy/admin_email_routes.dart:229` | `operatorInviteFirstAdmin` template wired and used. `operatorAdminInvite` template defined (line 89) — verify wired through SendGrid emitter. | Audit per addendum B4 ("defer the dual invite path decision to the code-health wave"). **Lane B flags but does not resolve** — dual invite path (Firebase password-reset reuse vs `operator_admin_invite` template) is Lane C's email pipeline. |
| Lens 7 Lifecycle | `auth_invites.revoked_at` + partial unique index `auth_invites_open_email_idx` | Revoke path exists. | Surface Cancel CTA per R1 #11: per-row Cancel with role + invited-by visible, 410 Gone on expired link, Undo toast within 10s. |
| Lens 13 Audit | `auth_events_audit` | Events captured. | Confirm `invite.cancel` event-type exists; if not, add. |

---

## B8 — Audit log hierarchy filter

| Lens | Code/doc checked | Finding | Required action |
|---|---|---|---|
| Lens 3 Data model | `db/migrations/202604280005_phase_9_0sigma_f_audit_logs.sql` (audit_logs definition), `db/migrations/202604290101_phase_9_hierarchy_access_wiring.sql:30,57-58` (`locations.org_unit_path` ltree + GiST index) | **`ltree` extension and `locations.org_unit_path` already exist.** ltree on `org_units.path` also exists (`db/migrations/202604280002_phase_9_0sigma_c_org_units.sql:56,82-94`). | **No new ltree migration needed** — addendum A3's "add Postgres `ltree` column on hierarchy tables" requirement is already satisfied. |
| Lens 4 Repository | n/a — admin audit-log read repository | No current hierarchy filter; current queries take `operator_id` only. | Add `listByHierarchy(operatorId, scopeType, orgUnitId?, locationId?, range)` method that issues the predicate `WHERE location_id IN (SELECT location_id FROM locations WHERE operator_id = $1 AND org_unit_path <@ $2::ltree)` for org_unit scope. Cache the descendant set per `(operator_id, org_unit_id)` — invalidate on hierarchy edit. |
| Lens 5 Proxy route | `tool/advisor_proxy/advisor_proxy.dart:6985` (`adminAuthAuditLogPath = '/v1/admin/auth/audit-log'`) | Today no hierarchy query params. | Add `?scope_type=…&org_unit_id=…&location_id=…&from=…&to=…` filter params. Reject invalid scope combinations. |
| Lens 6 Auth | `admin.audit_log.view`, `team.audit_log.view`, `team.audit_log.export` already in catalog. | None at catalog. | Confirm `team.audit_log.view` gates the operator-side hierarchy filter (scope confined to operator). |
| Lens 9 UX | New admin audit surface | None today | Build "Audit Log" page: scope picker (uses Codex's scope pane), date range, actor filter, action filter. Inheritance Tree component renders the scope tree. |
| Lens 10 Performance | r2 Topic 4 | "Re-open trigger from original lock: filter latency at scale". | Add a perf probe `audit_log_hierarchy_filter_p95_ms` per `(operator_id, location_count)` bucket. SLO: <500ms p95 at 100 locations. |
| Lens 13 Audit chain integrity | r2 Topic 2 Gotcha 3 — "hash-chained audit_logs is allergic to in-place row mutation" | No write changes here. | Confirm: filter is **read-only**. Add CI lint per addendum A7: `UPDATE audit_logs` outside an allowlist fails. |

---

## B9 — My Account surface

| Lens | Code/doc checked | Finding | Required action |
|---|---|---|---|
| Lens 2 IA | `lib/operator_web/screens/my_account_screen.dart:1-100`, `lib/operator_web/router/operator_web_router.dart:82,709,771` | `MyAccountScreen` exists with four cards (Profile, MFA, Password, T&Cs). | **The surface already exists**. Lane B's work is (a) add /sign-in-security 301 redirect; (b) consolidate Active Sessions card from `lib/screens/settings/settings_active_sessions_section.dart` into My Account; (c) wire the adaptive 2FA button (R1 #5 four states). |
| Lens 2 IA | grep `sign-in-security|signInSecurity` across `lib/` | **No `/sign-in-security` route exists in the codebase.** Email copy / push notifications may reference it externally. | Decision #7: 301 redirect ANY hit to `/operator-web/sign-in-security` (and admin equivalent) → `/my-account#security`. Lane B adds the route handler; email copy sweep is Lane C. |
| Lens 4 Repository | `lib/services/auth/proxy_account_info_gateway.dart`, `lib/services/auth/password_change_service.dart`, `lib/services/mfa/mfa_operations_gateway.dart` | All gateways in place. | None — wire into My Account cards. |
| Lens 5 Proxy route | `tool/advisor_proxy/advisor_proxy.dart:6960-6973` (password/MFA/sessions) | Routes wired. | None at the proxy. |
| Lens 6 Auth | RFC 9470 step-up on sensitive routes | **Today: no RFC 9470 implementation in proxy** (grep `insufficient_user_authentication` → only in addendum + research). Today MFA freshness is enforced via `lib/auth/fresh_mfa_resolver.dart` + `lib/auth/mfa_freshness_redirect_listener.dart` (custom freshness logic, not the OAuth standard challenge). | B11 ships RFC 9470 challenge; B9 consumes it. Until B11 lands, B9 uses the existing fresh-MFA listener for sensitive card actions. |
| Lens 9 UX | R1 #5 four states | Today's `lib/screens/settings/settings_mfa_section.dart` does not implement the 24h-grace state visually. | Add `MfaCardController` state machine: NotEnrolled → Enrolled → RemovalRequested(24h countdown) → Removable. Cross-device sync via existing `mfa_factor_removal_requests` table. |
| Lens 11 Parity | Mobile mirror — `lib/screens/settings/settings_active_sessions_section.dart` | Mobile section exists. | Lane C parity push. Lane B owns the operator-web My Account surface only. |
| Lens 13 Audit | `auth_events_audit` | Account/MFA/session events captured. | Confirm `session.revoke_all`, `password.change`, `mfa.enroll`, `mfa.removal_request`, `mfa.removal_cancel` are all emitted with consistent event_type strings. |

---

## B10 — Vendor-applicability table (single discriminated source)

| Lens | Code/doc checked | Finding | Required action |
|---|---|---|---|
| Lens 3 Data model | grep `vendor_applicability` across `db/migrations`, `lib`, `tool` | **No table exists.** Vendor capability is in code only: `tool/advisor_proxy/pos_adapter_registry.dart`, `labor_adapter_registry.dart`, `reservation_adapter_registry.dart` + `tool/advisor_proxy/vendor_capability_index.dart` (which exposes `pollOnlyVendorIds` derived from `kPosCapabilityProfiles`/`kLaborCapabilityProfiles`/`kReservationCapabilityProfiles`). | Add migration per addendum A6 + r2 Topic 5 schema sketch: `vendor_applicability (id uuid pk, operator_id uuid null, setting_kind text, setting_key text, vendor_slug text, enabled boolean, metadata jsonb, effective_from timestamptz, effective_until timestamptz null, created_at, created_by)`. Operator-id nullable for global F&F-admin defaults; NOT NULL for per-operator overrides. Unique index `(operator_id, setting_kind, setting_key, vendor_slug, effective_from)`. Partial index where `effective_until IS NULL` for current-state reads. |
| Lens 3 Data model | `db/migrations/202605050000_phase_8_data_accuracy_settings.sql:56-92` | `data_accuracy_settings.covers_source_*` (lunch/dinner/late_night) + `wage_source` are toggles ('vendor'/'forecast'/'manual'/'manual_mix'). The **list of which vendors can be authoritative** is implicit (code-defined). | B10 makes the list explicit and admin-editable. `setting_kind = 'covers'`, `'wage'`, `'polling'`. The toggle stays in `data_accuracy_settings`; the candidate-vendor list moves to `vendor_applicability`. |
| Lens 4 Repository | n/a | No repo. | Add `VendorApplicabilityRepository extends OperatorScopedRepository<VendorApplicabilityRow>`. Read methods return current-state rows by `(operator_id?, setting_kind)`. Write methods are INSERT-only — "ending" a row is UPDATE `effective_until = now()` + INSERT of new row, in one transaction. |
| Lens 5 Proxy route | n/a | None exists. | Add admin routes `GET/POST/PATCH /v1/admin/vendor-applicability`, super_admin only. Operator-side read at `GET /v1/operator/vendor-applicability?setting_kind=covers` filtered by operator. JSON schema validator per `setting_kind` (r2 Topic 5 Gotcha 2). |
| Lens 6 Auth | n/a — no key today | **Contract gap.** Permission to publish vendor-applicability rows is admin-tier. | Reuse `admin.roles.edit_seeded` is wrong (different surface). Either (a) gate behind generic `super_admin` role check; (b) add a new key `admin.vendor_applicability.edit`. Lane B recommends (a) at launch (super_admin only); flag (b) as a future catalog amendment if the surface opens to broader F&F admin tiers. |
| Lens 9 UX | n/a | None today. | Build "Vendor applicability" admin page: tabs per `setting_kind`, table with vendor + enabled toggle + effective dates + metadata JSON viewer. Plain-English copy ("Which vendors can act as the wage source?"). |
| Lens 11 Parity | `data_accuracy_settings` reader on operator-web | Reads `wage_source` enum but doesn't surface "which vendors are eligible". | Operator-web wage authority picker now filters by current `vendor_applicability` rows. |
| Lens 13 Audit | `audit_logs` | No event. | Emit `vendor_applicability.upsert` / `vendor_applicability.end` per write. Hash-chain integrity preserved (append-only). |

---

## B11 — JWT handoff replacement (redemption code + RFC 9470)

| Lens | Code/doc checked | Finding | Required action |
|---|---|---|---|
| Lens 3 Data model | grep `handoff_codes|redemption_code|/v1/auth/handoff` across `lib`, `tool`, `db/migrations` | **Zero matches** in production code. The only references are in research/decision docs. **No handoff implementation exists today.** | Add migration `db/migrations/<ts>_auth_handoff_codes.sql`: `handoff_codes (code text pk, user_id uuid, operator_id uuid, target_path text, expires_at timestamptz, consumed_at timestamptz null, source_device_fingerprint text, created_at timestamptz)`. 60-second TTL. Partial unique index `(code)`. Background reaper for expired rows. |
| Lens 5 Proxy route | n/a | None exists. | Add `POST /v1/auth/handoff/codes` (mobile creates code) + `POST /v1/auth/handoff/redeem` (web redeems). Atomic consume: `UPDATE handoff_codes SET consumed_at = now() WHERE code = $1 AND consumed_at IS NULL RETURNING ...`. 410 Gone on replay. Per-user rate limit 10/hour. |
| Lens 5 Proxy route | n/a | RFC 9470 challenge missing. | Add 401 challenge with `WWW-Authenticate: Bearer error="insufficient_user_authentication", acr_values="urn:mfa", max_age=300` on any sensitive route call where `auth_time` > 5min. Sensitive routes list: account edits, MFA enroll, role mutations, billing, vendor-applicability edits. |
| Lens 6 Auth | `lib/auth/fresh_mfa_resolver.dart`, `lib/auth/mfa_freshness_redirect_listener.dart` | Today's freshness check is custom — checks `auth_time` claim against a local TTL, redirects to MFA challenge if stale. **Not the RFC 9470 standard.** | Migrate to RFC 9470: the resolver still computes "stale?", but the proxy now sends the standard challenge instead of a 403 redirect. Web client reads `WWW-Authenticate`, surfaces step-up. The custom resolver stays as the freshness *check*; the *response* shape moves to the standard. |
| Lens 7 Lifecycle | Replay attack, expired code, wrong operator | None today. | Lifecycle rules: replay (consumed_at set) → 410 Gone; expired (expires_at past) → 410 Gone; wrong operator (web user_id != code user_id) → 403; sensitive landing without fresh MFA → 401 with RFC 9470 challenge. |
| Lens 8 Background/deploy | Cloud Run scaled instance reads code | Atomic consume must be transactional. | Postgres advisory lock NOT needed — UPDATE … RETURNING with unique pk + partial index does it. Cloud Run instances share the DB; concurrent redeem of the same code yields one success + N losers (no row returned). |
| Lens 9 UX | Handoff confirmation interstitial (R1 #6 Principle 1) | None today. | Web landing renders "Continue as user@email → <Target screen>" before redeeming for non-trivial targets. Skip for read-only landings. |
| Lens 11 Parity | Mobile deep-link emitter | Mobile today builds links that don't exist server-side. | Mobile sends `POST /v1/auth/handoff/codes` then opens `https://app.forgeflow.app/handoff?code=<opaque>`. Decision #5 originally said "reuse JWT"; A1 supersedes — Mobile changes to call the codes endpoint first. |
| Lens 13 Audit | `audit_logs` | No event. | Emit `auth.handoff.code_created` (actor=user, payload includes target_path) and `auth.handoff.redeemed` (actor=user, payload includes source_device_fingerprint, fresh_mfa_result). |
| Lens 14 Docs | `docs/contracts/` | No handoff contract today. | After Lane B implementation, contract owner adds `docs/contracts/auth_handoff_contract.md` capturing the redemption-code rules + RFC 9470 challenge list. Lane B FLAGS but does not write. |

---

## Cross-Cutting Findings (from the 14-lens deep pass)

### Contract gaps Lane B flags but does NOT amend

1. **`auth_permission_key_catalog.md`** does not yet list:
   - `admin.roles.catalog_publish` (if needed for B2 instead of reusing `admin.roles.edit_seeded`).
   - `admin.vendor_applicability.edit` (if B10 opens beyond super_admin).
   - `account.configure`, `business_timing.configure` (already flagged on catalog line 314+).
2. **No `auth_handoff_contract.md` exists.** B11 introduces one as a follow-up doc, written by the contract owner after Lane B implementation lands.
3. **Hierarchy presentation contract** — referenced by decision #1 carve-out language, not yet authored. New carve-outs (My Account user-scope, Default Role catalog global-scope) belong there.

### Existing infrastructure Lane B reuses (no new build)

- `locations.org_unit_path` (ltree, GiST) — `db/migrations/202604290101_phase_9_hierarchy_access_wiring.sql:30,57-58`.
- `org_units.path` (ltree, GiST) — `db/migrations/202604280002_phase_9_0sigma_c_org_units.sql:56,82-94`.
- `roles.role_id` UUID PK + `role_audit_log.role_id` UUID — `db/migrations/202604250008_auth_schema_foundation.sql:104`.
- `auth_invites` hierarchy-scoped — `db/migrations/202604290101_phase_9_hierarchy_access_wiring.sql:150-203`.
- `audit_logs` hash-chained per-operator/day — `db/migrations/202604280005_phase_9_0sigma_f_audit_logs.sql`.
- `EmailTemplateIds` for `operatorAdminInvite`, `backfillComplete`, `backfillFailed`, `auditAnchorFailure` — wired per B3 hot-fix (`lib/services/email/email_template_renderer.dart:131-170`).
- `MyAccountScreen` operator-web surface — `lib/operator_web/screens/my_account_screen.dart`.
- `lib/auth/fresh_mfa_resolver.dart` + `mfa_freshness_redirect_listener.dart` — custom freshness, will adapt to RFC 9470.
- `proxy_requests` idempotency cache — every new write route reuses.

### Shared seam dependencies on Lane A

- Inheritance Tree component (addendum C2) — Lane A code-health prerequisite. B6 (benchmark override UI), B8 (audit hierarchy filter UI), and any future inheritance display consume it. **Lane B's UI work cannot ship before Lane A's component.**
- Descendant-set cache for `(operator_id, org_unit_id) → location_id[]` — Lane A's repository utility. B8 + B6 hierarchy resolvers depend on it.
- Migration drift scanner update — Lane A handles `tool/migration_drift_scanner.dart --require-expand-contract` flag (r2 Topic 2 recommendation). Every new B migration runs through it.

### Shared seam dependencies on Lane C

- Email copy sweep from `/sign-in-security` → `/my-account#security` — Lane C. B9 ships the redirect; email templates point at the new URL when Lane C completes its sweep.
- Mobile parity for My Account, blended wage mix view-only, hierarchy breadcrumbs — Lane C.
- Dual invite path decision (Firebase reset-email reuse vs `operator_admin_invite`) — Lane C owns the audit (per addendum B4); B7 only fixes the dialog-level scope bug.

---

## Outputs by slice

The sequencing and file list lives in `03_execution_slices.md`. This matrix is
the per-lens evidence layer that the slice plan cites.
