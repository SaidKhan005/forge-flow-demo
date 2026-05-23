# Slice E: Admin Permission-Gating Migration (role-sets to capability-keys) + Error-Envelope Unification

**Type:** Implementation plan (design for review). **No code written.**
**Date:** 2026-05-23
**Author:** software-architect agent (read-only investigation; file:line cited throughout)
**Source items:** `seam_inheritance_audit_2026-05-22.md` W6 + §4 gaps (Permission enforcement GAP, Error-envelope GAP); cross-surface parity register G7/G8 (permission-key) + G63 (error envelope).
**Status:** AWAITING OPERATOR REVIEW. This slice is auth-gated per CLAUDE.md (auth-critical / proxy-touching). Nothing here is built until the operator signs off on §7.

---

## §0 Headline

**What E does.** It swaps the *mechanism* admin uses to decide "can this actor edit?" from **role-set string checks** (`session.roles.contains('super_admin')`) to **capability-key checks** (`session.permissions.contains(PermissionKeys.adminPricingTierEdit)` with a role-set fallback), bringing admin in line with how operator-web already gates. It also confirms the error-envelope posture (G63) and scopes the small unification work there.

**Why it is auth-gated.** Every site touched is a permission decision. A mechanism swap that is even slightly wrong either opens a destructive admin action (reset-MFA, PII-erasure, key-rotation, publish) to an actor who should not have it, or locks out a legitimate admin. Per CLAUDE.md this is the same gate as any auth-critical / proxy-touching slice: explicit operator approval, regardless of audit verdict.

**What stays unchanged (the binding promise of this slice).** The actual permission *decisions*, meaning who can do what, do not change. Today `super_admin` can edit and `ff_support` is read-only; after E that is still exactly true. This is a **representation change, not a policy change**:

- The **server-side proxy guard is already capability-key-based and is authoritative** (`lib/services/auth/proxy_admin_permission_guard.dart` evaluates `requestedPermissionKey` against the resolver + cache + MFA freshness, lines 22-184). E does **not** touch the server gate. The proxy already double-checks every write; the client gate is advisory UI honesty only (admin_routes.dart:130-132 says this in so many words).
- The **console admit gate** (`super_admin` OR `ff_support` may enter the admin console at all) is intentionally a role/claim check and **stays a role check**. The parity contract pins it as a Firebase-claim console gate (`team_roles_hierarchy_console_parity_contract.md:103,257`). E migrates the *sub-screen* gates that layer on top of admit, not admit itself.
- **Label-only role reads** (role to human-readable string) are not gates and are **preserved as-is**.

So E is: "give `AdminAuthSession` a `permissions` set hydrated from the same `/v1/auth/permissions/snapshot` operator-web already uses, then change the handful of edit-decision sites to prefer that set, falling back to today's role check when the snapshot is empty (demo / pre-hydration). Byte-identical decisions; better mechanism."

---

## §1 Gating-site inventory

The grep surfaced ~600 line hits, but the overwhelming majority are **propagation** of an already-computed boolean (`editingEnabled` / `actorIsForgeAdmin`) down widget trees and into gateway method signatures. Those are not decision sites and do not change. The actual **decision sites** (where a role-set is *evaluated* against the live session) are a small, enumerable set. Migrating the decision sites automatically corrects every downstream propagation, because the propagated flag's *value* is what changes, not its plumbing.

### 1a. True client-side gating DECISION sites (these are what E migrates)

| # | file:line | What it gates | Current check | Sensitivity |
|---|---|---|---|---|
| D1 | `lib/admin/admin_routes.dart:133-134` (`_isAdminSuperAdmin`) | Shared editing-gate predicate; the DRY'd source for the Pricing route's `canEdit` (consumed at :742) | `session != null && session.roles.contains(PermissionKeys.roleSuperAdmin)` | edit (pricing-tier mutate; MFA-pinned downstream) |
| D2 | `lib/admin/admin_routes.dart:856` (Support Operator View route) | `editingEnabled` for the cross-operator support workspace (Members/Roles/Security/Audit tabs) | `session != null && session.roles.contains('super_admin')` (bare literal) | edit + destructive (reset-MFA, PII-erasure flow downstream) |
| D3 | `lib/admin/admin_routes.dart:2008` (Roles+Hierarchy+Sessions route) | `editingEnabled` for roles/hierarchy/sessions mutations | `session != null && session.roles.contains('super_admin')` (bare literal) | edit + destructive (seeded-role edit, force-logout) |
| D4 | `lib/admin/admin_routes.dart:2370` (Audited Support Actions route) | `editingEnabled` for the audited-support surface | `session != null && session.roles.contains('super_admin')` (bare literal) | destructive (reset-MFA, paired-approval PII erasure, audit export) |
| D5 | `lib/admin/services/integration_admin_gateway.dart:176` (`_checkNotReadOnly`, rotateKey path) | Throws `PermissionDeniedException` to block provider-key rotation for read-only actors | `roles.contains(PermissionKeys.roleFfSupport)` (deny-if-support) | destructive (provider key-rotation, MFA-required) |
| D6 | `lib/admin/services/integration_admin_gateway.dart:772` (second `_checkNotReadOnly`) | Same deny-if-support guard on the second mutate path in this gateway | `roles.contains(PermissionKeys.roleFfSupport)` | destructive (key-rotation) |

**True client-side gating decision sites: 6** (4 share the same `super_admin`-edit semantics; 2 are the inverse `ff_support`-deny semantics in the integration gateway).

### 1b. Already-correct model site (do NOT re-migrate; it is the template)

| file:line | What it gates | Current check | Note |
|---|---|---|---|
| `lib/admin/screens/default_role_catalog_admin_screen.dart:100-148` (`kDefaultRoleCatalogScreenViewRoles` / `…EditRoles` / `defaultRoleCatalogScreenCanEdit`) | View/edit of the F&F default role catalog | role-tier set, **but already aliased to the keys** `team.roles.default_catalog.view` / `.edit` and already carrying an `actorHasEditKeyHint` parameter + a documented "switch to `resolver.has(...)` and drop the role-tier check" migration path | This is the **target shape minus the live snapshot**. E should fold it into the same mechanism (feed the real `permissions` set into `actorHasEditKeyHint`), not rebuild it. |

### 1c. Console-admit gate (PRESERVE as a role/claim gate; explicitly out of scope for the mechanism swap)

| file:line | What it gates | Current check | Why it stays |
|---|---|---|---|
| `lib/admin/admin_auth_gate.dart:54-57` (`kAdminConsoleRoles`) + `:96` (`isAdmin`) + `:601` (`_emitForCredential`) | Whether a signed-in Firebase user is admitted to the admin console at all | `roles.any(kAdminConsoleRoles.contains)` over `{super_admin, ff_support}` | The parity contract pins console-level gating as a `super_admin`/`ff_support` Firebase **claim** check (`…parity_contract.md:103,257`). The JWT only carries `is_super_admin`/`is_ff_support` booleans (admin_auth_gate.dart:654-674); there is no "console.admin" capability key, and inventing one is a new-key decision (see §7). Admit-vs-forbidden is a claim concern, not a per-action capability. |

### 1d. Label / display-only role reads (PRESERVE; not gates, change nothing)

These read roles to render a human-readable string. They gate no action and must not be migrated (migrating them would be churn with zero security value and some regression risk):

| file:line | What it renders |
|---|---|
| `lib/admin/admin_shell.dart:583-592` (`_RolePill`) | Header role chip label ("Ecosystem admin" / "Support access") |
| `lib/admin/screens/my_account_admin_screen.dart:444-448` (`_readableAdminRole`) | My-account role label |
| `lib/admin/widgets/data_accuracy_audit_history_panel.dart:253-262` | Maps `actor_kind` strings (incl. `'ff_support'`) to display labels. This is an **audit-row actor label**, not the live session at all. |
| `lib/admin/services/roles_hierarchy_sessions_admin_gateway.dart:1166-1167` | Static role-key to display-name map for rendering other users' roles |
| `lib/admin/services/debug_console_admin_gateway.dart:630,649` | Writes `'actor_role': 'ff_support'` into a demo audit fixture (test data) |

### 1e. MFA-freshness affordance gates (already correct; leave alone)

The four MFA-pinned affordances (`canEditSeededRoles`, `canResetMfaFactors`, `canIssuePairedErasure`, `canExportAuditLog`) are already resolved off the JWT `auth_time` claim via the shared `FreshMfaResolver` (`admin_routes.dart:_isAdminMfaFresh` at :110-123, consumed :869-872, :2019, :2379-2382). These are an **orthogonal freshness dimension**, not a role-set check, and the proxy re-checks freshness server-side (`proxy_admin_permission_guard.dart:169-175`). E does not touch them, but note their interaction with the migrated `editingEnabled` in §4/§6.

**Inventory totals.** 6 sites to migrate (1a) · 1 template to fold in (1b) · 1 admit gate preserved as a claim check (1c) · 5 label/test reads preserved (1d) · 4 MFA-freshness gates untouched (1e).

---

## §2 Role to capability-key mapping

The authoritative mapping is the parity contract's **Permission gate cheat sheet** (`team_roles_hierarchy_console_parity_contract.md:259-268`). Every `admin.*` key it references already exists in the frozen catalog (`lib/auth/permission_keys.dart:112-150`). The migrated sites compute `editingEnabled` as a *single per-route boolean* today; the cheat sheet shows each route actually fronts several mutate actions, so the precise target is a **per-action key check at the affordance**, with the route-level `editingEnabled` retained as a coarse "any-edit-here" gate for backward compatibility.

| Site | Route / action it fronts | Current role check | Target capability key(s) (already in catalog) | New key needed? |
|---|---|---|---|---|
| D1 (Pricing) | pricing-tier view/edit | `super_admin` | edit affordances need `admin.pricing_tier.edit` (MFA, keys.dart:137); read always allowed for admitted actor (`admin.pricing_tier.view`, :136) | No |
| D2 (Support Operator View) | members + roles + security + audit tabs | `super_admin` | members write: `admin.users.{create,deactivate,reactivate,soft_delete,reset_password,reset_mfa_factors}`; roles write: `admin.roles.{create_custom,delete_custom,assign,revoke,edit_seeded}`; audit export: `admin.audit_log.export`; sessions: `admin.session.force_logout` (keys.dart:113-142) | No |
| D3 (Roles+Hierarchy+Sessions) | roles CRUD, org-unit/location mutate, force-logout | `super_admin` | `admin.roles.{create_custom,delete_custom,assign,revoke,edit_seeded}` + `admin.session.force_logout` (keys.dart:127-142). Hierarchy org-unit mutate has **no dedicated key** today; cheat sheet maps it to "`admin.users.create` analog" (line 263) | **Flag:** hierarchy org-unit/location mutate (`createOrgUnit`, `moveOrgUnit`, `renameOrgUnit`, `deleteOrgUnit`, `moveLocation`, `setLocationSuspended`, `deleteLocation` in `roles_hierarchy_sessions_admin_gateway.dart`) has no `admin.hierarchy.*` key. See §7 Q1. |
| D4 (Audited Support Actions) | reset-MFA, password reset, paired PII erasure, audit export | `super_admin` | `admin.users.reset_mfa_factors` (MFA, :123), `admin.users.reset_password` (:119), `admin.users.erase_pii` (MFA, :118), `admin.audit_log.export` (:134) | No |
| D5 / D6 (Integration key-rotation) | provider key rotation (deny-if-support) | `ff_support` (deny) | `integration.key_rotate` (MFA, keys.dart:228): invert from deny-list to allow-list, gating on holding the key rather than not-being-support | No |
| 1b (Default role catalog) | catalog view/publish | role-tier (already key-aliased) | `team.roles.default_catalog.view` / `.edit` (keys.dart:188-191): already wired, just feed live `permissions` into `actorHasEditKeyHint` | No |

**Mapping coverage.** Of the 6 decision sites + 1 template, **6 of 7 map cleanly onto existing catalog keys**. **One gap:** the hierarchy org-unit/location mutate actions in D3 have no `admin.hierarchy.*` capability key. Today they ride the route-level `super_admin` `editingEnabled`. Options (operator decides, §7 Q1): (a) keep those specific affordances on the coarse admit+`super_admin` fallback and migrate only the keyed actions in D3; (b) add `admin.hierarchy.{create,move,rename,suspend,delete}` keys, but **adding keys to the frozen catalog is itself an operator-gated change** (CLAUDE.md "Adding a new key" requires the constant + `PermissionKeys.all` + the migration seed + the catalog doc + a re-seed, and passes Phase 9.6 review). Recommendation: **(a) for this slice**. Do not expand the catalog under an auth-migration slice; treat hierarchy-mutate keys as a separate, later, operator-decided slice.

---

## §3 Error-envelope unification (G63)

### Current state: honest assessment

This is **not** symmetric with the gating gap, and the audit's framing matters:

- **Admin is already the *more* consistent surface.** Every admin gateway throws a structured `{statusCode, errorCode, message}` exception (`AdminSecurityGatewayError` at `admin_security_gateway.dart:71-86`; `AdminBusinessTimingResolutionGatewayError` at `admin_business_timing_resolution_gateway.dart:40-53`; demo gateways mirror the same shape). The `error` field is read uniformly from the proxy body (`(body['error'] as String?) ?? 'unknown_error'`).
- **Admin already centralizes the two cross-cutting cases** every gateway needs, in one chokepoint `sendAdminHttpRequest` (`admin_http_timeout.dart:103-179`): (1) the `mfa_freshness_required` 403 to sign-out + redirect (`:155-177`), and (2) the 401 to force-refresh-token to retry-once recovery (G71, `:123-148`). No admin gateway re-implements these.
- **The G63 gap is operator-web-side.** The cross-surface register (`cross_surface_parity_audit_2026_05_16.md:209`) cites `web_team_roles_gateway.dart:355-364`, `web_team_users_gateway.dart:535-544`, `web_security_gateway.dart:903-917`, `operator_web_proxy_client.dart:326-343`: each operator-web gateway "invents its own error code; none distinguish 409 replay vs real conflict; 2FA-freshness 403 handled inconsistently across screens."
- **There is no shared error-envelope contract doc.** (Glob for `docs/contracts/**error**` returns nothing.) So "unify" cannot mean "conform to an existing spec"; the spec must be written as part of this work.

### What "unify error envelopes" concretely means here

Three concrete deliverables, smallest-first:

1. **Write the envelope contract.** A new `docs/contracts/proxy_error_envelope_contract.md` (Tier-2; **operator-approval-gated to create**, per Authority Order) that pins: the wire shape `{ "error": "<machine_code>", "message": "<human>", "details"?: {...} }`; the canonical machine codes (at minimum `validation_failed`, `permission_denied`, `mfa_freshness_required`, `idempotency_replay` for 409-replay-vs-conflict, `not_found`, `conflict`, `rate_limited`, `internal`); and the client mapping (which HTTP status pairs with which code). This documents what the proxy *already emits* (admin's `errorCode` reads + the freshness contract are de-facto compliant) plus the missing `idempotency_replay` distinction.

2. **Operator-web conforms to it** (the actual G63 fix, on the operator-web lane, paired with this admin slice per the parity contract's "pair lands together" rule, lines 280-281, 293). A shared `WebProxyErrorEnvelope.tryParse(statusCode, body)` helper that the four cited operator-web gateways funnel through, so they stop each inventing codes, plus a single discriminator for 409 `idempotency_replay` vs real `conflict`.

3. **Admin verifies + closes the small residue.** Admin is mostly compliant; the residue is: (a) confirm every admin gateway maps the proxy `error` body field to its `errorCode` (most do; see `admin_security_gateway.dart:469`); (b) ensure the 409-replay-vs-conflict distinction exists admin-side too (today admin gateways do not special-case 409: they fall to the generic `statusCode/errorCode` path). This is a few-line addition per gateway, not a rewrite.

**Honest scope note.** The bulk of G63 is operator-web work, not admin work. Including it in "Slice E" only makes sense because (i) it shares the auth/proxy seam and the operator-approval gate, and (ii) the parity contract requires the admin and operator-web halves of a parity item to land together. If the operator prefers, G63 can be **split out as its own paired slice** and E can be the pure permission-key migration (§7 Q4).

---

## §4 Safe sequencing

E is broken into independently-reviewable sub-slices, ordered low-risk to high-risk, each shaped like the 23 already-merged UX-parity slices (worktree to commit + push to PR to STOP; orchestrator audits Pattern B + gate-checks; operator approves the auth-touching ones).

| Sub-slice | Scope | Risk | Mechanical or behavioral? |
|---|---|---|---|
| **E0** (prereq, no gate) | Add a `permissions` field to `AdminAuthSession` (mirror `OperatorWebSession.permissions`, op_web_auth_source.dart:57) + thread it through the demo factories as **empty** so every current code path hits the role-set fallback and behaves byte-identically. Wire the existing `/v1/auth/permissions/snapshot` loader (`proxy_permission_snapshot_loader.dart:111`) into `FirebaseAdminAuthSource` (web-safe variant, see §6 risk). **No gate site changed yet.** | Low | Mechanical (additive field; empty in demo means no behavior change) |
| **E1** (pure-mechanical, low gate) | Replace D1's `_isAdminSuperAdmin` body + D2/D3/D4's bare `roles.contains('super_admin')` with a shared `_adminCanEdit(session, {requiredKey})` helper that does `if (session.permissions.isNotEmpty) return session.permissions.contains(requiredKey); return session.roles.contains(roleSuperAdmin);`, **identical to operator-web's `_canView`/`_canExport` pattern** (audit_log_screen.dart:175-187). With E0 shipping empty permissions, the fallback path keeps decisions byte-identical until the snapshot is live. | Low-medium | Mechanical (same decision; new code path dormant until snapshot hydrates) |
| **E2** (default-role-catalog fold-in) | Feed the live `permissions` set into `default_role_catalog_admin_screen.dart`'s already-present `actorHasEditKeyHint` (:126-148); the role-tier check stays as the documented fallback. | Low | Mechanical (the hint plumbing already exists) |
| **E3** (integration key-rotation invert) | Migrate D5/D6 from deny-if-`ff_support` to allow-if-holds-`integration.key_rotate`, fallback to the inverse role check. Security-sensitive (key-rotation), so **operator approval**. | Medium-high | Behavioral edge: inverting a deny-list to an allow-list changes the decision for any *future* role that is neither `super_admin` nor `ff_support` (today none reach this gateway, but the inversion is a real semantic change that must be tested both directions). |
| **E4** (per-action key granularity) | Where a route's single `editingEnabled` fronts several distinct actions (D2/D4 especially), split the affordance-level gates onto their specific keys per the cheat sheet (e.g. reset-MFA on `admin.users.reset_mfa_factors`, erasure on `admin.users.erase_pii`). Pure tightening toward the contract; **destructive actions get careful per-action treatment + operator approval**. | High | Behavioral: this is where a too-wide or too-narrow key mapping would actually change who can do a destructive action. Each action audited individually against the cheat sheet. |
| **E5** (error envelope) | The §3 work: contract doc (gated), then operator-web conformance (paired lane), then admin residue. Can be sequenced last or split out entirely (§7 Q4). | Medium | Mixed (operator-web behavioral; admin near-no-op) |

**Why this order is safe.** E0+E1+E2 are *mechanism-dormant*: with an empty `permissions` set they exercise the role-set fallback and produce byte-identical decisions, so they can merge and bake before any live snapshot flips the active path. The behavioral edges (E3 inversion, E4 destructive-action granularity) come last, each small, each individually testable against a known before/after truth table.

**Security-sensitive gates get their own treatment.** reset-MFA (D4, `admin.users.reset_mfa_factors`), PII-erasure (D4, `admin.users.erase_pii`), publish (1b, `team.roles.default_catalog.edit`), key-rotation (D5/D6, `integration.key_rotate`) are each: (1) MFA-pinned already (keys.dart:363-374) and that freshness gate is **not** touched; (2) re-checked server-side by the proxy guard regardless of the client; (3) given an explicit before/after actor truth-table test in §5; (4) landed in E3/E4 under operator approval, never folded into the mechanical E1.

---

## §5 Test strategy

The migration's contract is "**same actors allowed/denied before and after**." Every site gets a test that proves the decision is invariant under the mechanism swap. The proof obligation is a **truth table per gate**: for each (actor-role, snapshot-state) pair, assert the same `editingEnabled` / allow / deny outcome pre- and post-migration.

| Gate | Test that proves the decision is unchanged |
|---|---|
| D1-D4 (route `canEdit`) | Widget/unit test the shared `_adminCanEdit` helper across the matrix: {`super_admin`, `ff_support`, hypothetical non-admit role} times {empty permissions (fallback), permissions-with-key, permissions-without-key}. Assert: `super_admin` + empty gives true (fallback); `ff_support` + empty gives false; `super_admin`-held-key gives true; key-absent gives false. Compare against the pre-slice `roles.contains('super_admin')` result on the fallback rows (must match exactly). |
| D5/D6 (key-rotation invert) | Both directions: `ff_support` is still denied (was deny-list, now key-absent); `super_admin` is still allowed; assert the `PermissionDeniedException` still throws on the same actors. Inversion regression test: a role that holds `integration.key_rotate` but is not `super_admin` is now allowed (document this as the intended new degree of freedom, not a regression). |
| 1b (default role catalog) | Existing `test/admin/default_role_catalog_admin_screen_test.dart` already covers the role-tier path; add a row feeding `actorHasEditKeyHint` to assert hint-and-role agreement, and assert the `debugPrint` mismatch warning fires when they disagree (the helper's existing defense-in-depth, :133-147). |
| E4 destructive actions | Per-action truth table for reset-MFA / erasure / export: assert the affordance is enabled iff (admit AND MFA-fresh AND holds-the-specific-key-or-fallback). Cross-check the MFA-freshness dimension is unchanged (still gated by `_isAdminMfaFresh`). |
| Console admit (unchanged) | Existing `admin_auth_gate` tests must still pass untouched. They are the regression sentinel proving admit-vs-forbidden did not move. |
| Catalog integrity | `dart run tool/permission_key_lint.dart` must stay clean (it checks the Dart-to-catalog-doc mirror for drift/orphan/missing, permission_key_lint.dart:35-44). If §7 Q1 adds hierarchy keys, the lint + the migration-seed test (`test/advisor_proxy_jwt_verifier_test.dart` "auth schema foundation") both gate it. |
| Parity acceptance | Per `team_roles_hierarchy_console_parity_contract.md:270-281`: the web build (`flutter build web -t lib/main_admin.dart --dart-define=ADMIN_DEMO_AUTH=true`) must succeed with no `dart:io` import error (the snapshot loader is `dart:io`-based, see §6 R3); at least one widget test asserts the permission gate per the cheat sheet; the operator-web half of any paired item lands together. |

`tool/permission_key_lint.dart` is the standing guardrail. It does **not** check gating-site usage, only catalog-mirror integrity, so it will not by itself catch a wrong key choice; the §5 truth-table tests are what catch that.

---

## §6 Risks & rollback

| # | Risk | Mitigation / rollback |
|---|---|---|
| R1 | **A gate opens too wide:** a migrated key check admits an actor the role check denied (e.g. a destructive action exposed to `ff_support`). | The fallback path is provably identical (§5 truth tables on the empty-snapshot rows). The live-snapshot rows are tested against the cheat sheet. Server-side proxy guard is the backstop and is unchanged (`proxy_admin_permission_guard.dart`). Rollback: each sub-slice is one revert; E0 leaves `permissions` empty so reverting E1 instantly restores the pure role check. |
| R2 | **A gate locks out a legitimate admin:** snapshot hydration fails or returns an incomplete key set, and the new path denies a `super_admin`. | The `if (permissions.isNotEmpty)` guard means an *empty* snapshot (load failure / pre-hydration) falls back to the role check, same as operator-web (audit_log_screen.dart:176). A *non-empty but wrong* snapshot is a proxy bug, not a client bug, and the proxy is the source of truth. Add a test for empty-snapshot giving the role fallback. |
| R3 | **`dart:io` leak breaks the admin web build.** The snapshot loader's concrete client is `DartIoProxyPermissionSnapshotHttpClient` (`proxy_permission_snapshot_loader.dart:55`), and admin is a web build that must stay `dart:io`-free (parity contract:275,289). | E0 must wire the snapshot through a **web-safe `package:http` client** behind the existing `ProxyPermissionSnapshotHttpClient` interface (:48-53), or reuse admin's existing `sendAdminHttpRequest` chokepoint (`admin_http_timeout.dart`, already `package:http`). Do NOT import the `DartIo` impl from anything reachable by `lib/main_admin.dart`. This is a build-time check (the parity acceptance web-build gate, §5) so a leak fails CI-style before merge. |
| R4 | **Inversion semantics (D5/D6).** Flipping deny-if-`ff_support` to allow-if-key changes behavior for any role that is neither `super_admin` nor `ff_support`. | Today no third role reaches this gateway, so the live decision is unchanged; but the inversion is a real semantic change that must be (a) tested both directions, (b) called out to the operator (§7 Q2). Rollback: revert E3 alone. |
| R5 | **Adding hierarchy keys (if §7 Q1 picks option b) widens the frozen catalog.** | Catalog additions are operator-gated and pass Phase 9.6 review + the lint + the seed-mirror test. Recommendation is **not** to add keys in this slice (option a). |
| R6 | **Drift while CI is dark** (until 2026-06-01). | Per CLAUDE.md Cost & Convergence #6: run `tool/pre_merge_gate.sh` + `tool/verify_pr_landed.sh` on each sub-slice (all touch auth). Serialize the sub-slices (they touch the same files admin_routes.dart / admin_auth_gate.dart): do not parallelize per Cost & Convergence #3. |

**Reversibility summary.** Every sub-slice is a single-PR revert. E0's empty-permissions design makes the whole chain *fail-safe-by-default*: until a real snapshot is live, the system behaves exactly as today, so even a fully-merged E0 to E2 can sit dormant and be reverted with zero behavioral delta.

---

## §7 Open questions for the operator

1. **Hierarchy-mutate keys (Q1).** Org-unit/location create/move/rename/suspend/delete (in `roles_hierarchy_sessions_admin_gateway.dart`) have **no `admin.hierarchy.*` capability key**; the cheat sheet hand-waves them as "`admin.users.create` analog." Pick one:
   - **(a, recommended)** Leave those specific affordances on the coarse admit + `super_admin` fallback for this slice; migrate only the keyed actions. No catalog change.
   - **(b)** Add `admin.hierarchy.{create,move,rename,suspend,delete}` keys. This is a frozen-catalog expansion (gated, Phase 9.6 review, lint + seed-mirror). Bigger, separate slice.
2. **Integration key-rotation inversion (Q2).** D5/D6 today deny `ff_support`. Migrating to "allow if holds `integration.key_rotate`" is cleaner but changes the decision for any future non-admit role. Confirm we want the allow-list semantics (recommended, it matches the rest of the model), accepting that it is a deliberate semantic change tested both ways.
3. **`ff_support` read-only key mapping (Q3).** `ff_support` is "read-only" by convention (it simply lacks the `.edit`/mutate keys). Confirm there is **no** affirmative `ff_support`-can-read key we must add, i.e. read access for an admitted actor is implied by admit, and only *writes* are key-gated. (This is how the cheat sheet reads; confirming it pins the whole §2 mapping.)
4. **G63 scope (Q4).** The error-envelope work is mostly operator-web, plus a new Tier-2 contract doc. Do you want it **inside Slice E** (paired admin+op-web landing per the parity contract) or **split into its own paired slice**, leaving E as the pure permission-key migration? (Recommendation: split. It keeps E focused and smaller; G63's center of gravity is operator-web.)
5. **Error-copy wording (Q5).** If G63 is in scope, the new `permission_denied` / `idempotency_replay` / `mfa_freshness_required` user-facing strings must read as plain-English training copy (UX writing standard) and pass `tool/ux_em_dash_lint.dart`. Operator to confirm the copy at review time (placeholder strings in the plan, finalized on build).
6. **New-key catalog gate (Q6, conditional).** If Q1 picks (b) or any new key surfaces, that catalog addition is itself the operator-approval gate per CLAUDE.md "Adding a new key" + the Ceiling-raise discipline. Explicit sign-off needed before the migration that depends on it.

---

## Appendix: load-bearing references (all verified to exist)

- Frozen catalog: `lib/auth/permission_keys.dart` (admin.* :112-150; team.roles.default_catalog.* :188-191; requiresMfa :363-374).
- Target client pattern: `lib/operator_web/screens/audit_log_screen.dart:175-187` (`_canView`/`_canExport` snapshot-first + role fallback); `OperatorWebSession.permissions` `lib/operator_web/auth/operator_web_auth_source.dart:57`.
- Authoritative server gate (unchanged by E): `lib/services/auth/proxy_admin_permission_guard.dart:22-184`.
- Snapshot loader: `lib/services/auth/proxy_permission_snapshot_loader.dart:48-111` (path `/v1/auth/permissions/snapshot`).
- Admin admit gate (preserved): `lib/admin/admin_auth_gate.dart:54-57,96,601`.
- Admin error chokepoint (already centralized): `lib/admin/services/admin_http_timeout.dart:103-179`.
- Canonical mapping: `docs/contracts/team_roles_hierarchy_console_parity_contract.md:103,255-268` (Permission gate cheat sheet); acceptance gates :270-293.
- G63 source citations: `docs/_audits/cross_surface_parity_v1/cross_surface_parity_audit_2026_05_16.md:209`.
- Guardrail lint (catalog-mirror only): `tool/permission_key_lint.dart`.
