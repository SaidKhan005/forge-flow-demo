# 01 — Product Rule And Information Architecture (Lane B — Features)

Status: planning draft, 2026-05-12 (post-Codex wave Step 3, Lane B).
Authority: CLAUDE.md, `docs/_decisions/post_codex_wave_decisions_2026-05-12.md`,
`docs/_decisions/post_codex_wave_decisions_addendum_2026-05-12.md`,
`docs/contracts/auth_permission_key_catalog.md`, HP #11.

## Plain-English Product Rule

Forge & Flow runs as one product surface for restaurant operators. Every
operator-facing behaviour, every label, every audit row, every notification, and
every gate must obey four product rules at the same time:

1. **Hierarchy everywhere.** Business → org unit → location. A setting can be
   applied at any scope and is inherited downward. The lowest configured scope
   wins. Every settings/people/roles/audit/security surface shows the selected
   scope, the inherited source, and the effective value. Carve-outs (today:
   integrations are location-only) must be documented and labelled in the UI.
2. **Trust + Account Control.** The operator must always be able to answer:
   "Who has access? What does this person see? When was this changed? How do I
   undo it? Is my account safe?" Role editor, default-role catalog admin,
   adaptive 2FA, mobile→ops-web handoff, My Account, invite cancel, edit-user,
   and inheritance display are one cohesive design language (R1 #1/#2/#5/#6/#8).
3. **Two products, one shell.** Permissions, roles, and editor taxonomy are
   structured as sibling products `Forge & Flow` and `Barrio` from day one.
   Barrio permissions sit dormant; the seam is visible so unpausing Barrio is a
   surface flip, not a re-architecture.
4. **F&F admin is the catalog authority; operator is the catalog consumer.**
   Default Roles are read-only inside operator businesses. F&F admin edits the
   global Default Role catalog and publishes new versions; businesses pull the
   pinned-or-latest version at read time (addendum A2). Operators customize by
   building Custom Roles only.

## Authority and Scope Model

| Layer | Owner | What it carries | Edit surface |
|---|---|---|---|
| Default Role catalog | F&F admin | Versioned global role definitions (permission keys per default role). Immutable history; new publishes replace the latest pointer. | Admin console "Default Roles" (new B2) |
| Default Role grant | Operator (read-only) | Operator businesses see the resolved catalog version, by name. No edit affordance. | Read-only inside operator role list |
| Custom Role | Operator owner / admin | Operator-scoped role; chooses permission keys from the frozen catalog. | Operator-web custom role editor (already shipped 9.6) + admin parity in B4 |
| Role grant (`user_roles` row) | Operator owner / admin | (`user_id`, `role_id`, `scope_type`, `org_unit_id`/`location_id`). Hierarchy-scoped. | People-access-roles tile (already shipped) |
| Permission key catalog | F&F engineering (code-frozen) | `lib/auth/permission_keys.dart` + seed migration; mirrors `docs/contracts/auth_permission_key_catalog.md`. Operators cannot invent keys. | Code release only |
| Vendor applicability (NEW) | F&F admin | Per-(setting_kind, setting_key, vendor) row in `vendor_applicability`. Replaces three per-feature lists (wage/covers/polling) with one shape. | Admin console "Vendor applicability" (new B10) |

## Role Identifier Model (B3)

Every role row carries an immutable UUID (`roles.role_id`, already present at
the schema level — see `db/migrations/202604250008_auth_schema_foundation.sql`
line 104). The hybrid model going forward:

- `role_id` — UUID, immutable, the only identifier used by `role_permissions`,
  `user_roles`, `auth_invites`, `role_audit_log`, and any catalog payload.
- `role_key` — short slug. Today: seeded as `super_admin`, `ff_support`,
  `operator_owner`, `operator_manager`, `operator_supervisor`, `operator_staff`.
  After B3: presentational only. Renames are cheap and never migrate grants.
- `display_name` — user-supplied display copy. Already free to change.

UX rule: no operator surface ever asks for `role_key`. The slug is derived from
`display_name` for new operator-scoped roles and surfaced read-only in admin
tooling for debug purposes. Code-level references continue to use the seeded
slugs for the six baseline roles because they are physical seed keys — the slug
is the *catalog membership signal*, not an identifier. After B3, every new code
path references roles by `role_id`.

## Default Role Catalog Resolution (B2)

Pull pattern (addendum A2). The flow at read time:

1. Operator opens role list.
2. Server reads `businesses.default_role_catalog_version_id` (NULL = follow
   latest).
3. Server selects from `default_role_catalog_versions` the matching payload.
4. Server resolves the payload's role list and joins to live `roles`/`role_permissions`
   filtered by the rows the catalog version names. Custom roles are unioned in.
5. Response surfaces "Default" badge on catalog-driven roles, "Custom" pill on
   operator-scoped ones, and a "Updated by F&F on <date>" annotation when the
   business's pinned version differs from the previously-viewed version.

The catalog payload is immutable per `version_id`; the only mutable pointer is
on the business row. Publish writes one row to `default_role_catalog_versions`
+ one row to `audit_logs` with payload SHA-256.

## Two-Product Taxonomy (B4)

The permission key catalog already has product-prefixed namespaces
(`product.forgeflow.access`, `product.barrio.access`, `forgeflow.*`, `barrio.*`).
The role editor surface (admin + operator) groups permissions by product first,
then by resource. UI shape: two sibling tabs — `Forge & Flow` and `Barrio` —
with `Barrio` rendered but flagged "Coming soon" or dormant on operators whose
plan does not include it. The schema does not branch by product; product-scoped
permission keys naturally carry the boundary.

## Admin Console Access Control (B5)

Three classes of users hit the admin shell:

| Role | What they see | What they edit |
|---|---|---|
| `super_admin` (F&F engineering / ops) | Everything | Everything, including Default Role catalog publish, vendor applicability, pricing tier |
| `forge_admin` (Postgres role) | Same as super_admin via JWT bridging | Same |
| `ff_support` | Read-only across operator businesses they support; admin audit view; "View as operator" support workflow | Bounded write: invite resend, MFA reset (paired-approval), session force-logout. Cannot publish catalog. |
| `operator_owner` / `operator_admin` | Operator-scoped admin surfaces (own business). My Account. | Custom roles, role grants, invites, settings, integrations, sessions, audit (own business) |
| `operator_manager` | Manager-tier subset | Manager-tier subset (no custom role create, no hierarchy delete) |
| Below manager | None of the admin shell | n/a |

Every admin surface enforces the gate at the proxy route AND in UI so a
forbidden user sees a plain-English "Only F&F staff can publish role catalogs"
copy, not a generic 403.

## My Account Surface (B9)

Single surface, four cards (`/operator-web/my-account` already exists at
`lib/operator_web/screens/my_account_screen.dart`):

| Card | Owns | Permission |
|---|---|---|
| Profile | Display name, email, phone, photo | Self-edit |
| Security | Password change, sign-in history | Self-edit with step-up |
| MFA | Adaptive 2FA button (4 states from R1 #5) + enrolled factors | Self-edit with step-up |
| Active Sessions | Per-device list, "Sign out all other sessions" | Self-edit with step-up |

The `/sign-in-security` URL (decision #7) returns 301 to `/my-account#security`.
Audit log link at the bottom of every card points at the dedicated audit
surface; My Account never inlines audit content (separation of concerns).

## Audit Log Hierarchy Filter (B8)

Read-side join (decision #8 + addendum A3). The `audit_logs` table is not
modified. The filter UI walks the operator's current hierarchy tree, sets a
selected scope (business / org_unit / location), and the proxy resolves the
predicate:

```sql
WHERE operator_id = $1
  AND (
    location_id = $2                                        -- location scope
    OR location_id IN (
      SELECT location_id FROM locations
      WHERE operator_id = $1
        AND org_unit_path <@ $3::ltree                      -- org_unit scope
    )
  )
```

`locations.org_unit_path` (ltree) already exists in
`db/migrations/202604290101_phase_9_hierarchy_access_wiring.sql`. The
descendant-set cache becomes Lane A's "Inheritance Tree shared component"
prerequisite (C2 in the addendum).

## Vendor Applicability Surface (B10)

One Postgres table `vendor_applicability` with `setting_kind` discriminator
replaces three separate per-feature surfaces (wage authority list, covers
authority list, polling authority list). F&F admin edits via the admin console;
operator-web reads at the location scope where the setting is applied.

Operator-visible behaviour: when an operator picks a `wage_source` in Data
Accuracy, the UI shows only vendors where
`vendor_applicability.setting_kind = 'wage' AND enabled = true AND
effective_until IS NULL`. The list updates without a code release whenever F&F
admin edits the table.

## Redemption-Code Handoff (B11)

Decision #5 is **superseded** by addendum A1. Mobile → Ops Web hand-off uses a
one-time short-TTL opaque code; the JWT never appears in the URL.

UX (operator-visible) is identical to the original decision: tap "Manage X on
Ops Web" → browser opens already signed in. The implementation:

1. Mobile asks proxy for a handoff code (POST `/v1/auth/handoff/codes`).
2. Proxy stores `(code, user_id, target_path, expires_at, consumed_at NULL)`,
   60-second TTL.
3. Deep link opens `app.forgeflow.app/handoff?code=<opaque>` (NOT a JWT).
4. Web client POSTs the code to `/v1/auth/handoff/redeem`; proxy atomically
   marks `consumed_at`, returns a fresh session.
5. Sensitive landings (account edits, MFA enroll, role mutations, billing)
   trigger RFC 9470 step-up via `WWW-Authenticate: Bearer
   error="insufficient_user_authentication", acr_values="urn:mfa", max_age=300`.
   Web client redirects to MFA challenge; on success it retries the original
   landing.

Every redemption emits an `audit_logs` row (actor, source device fingerprint,
target route, fresh-MFA result).

## Hierarchy-Everywhere Carve-Outs

Carve-outs must (a) be documented in the relevant contract and (b) be labelled
in the UI explaining why the surface is not hierarchy-scoped:

| Carve-out | Surface | Why | UI signal |
|---|---|---|---|
| Integrations are location-only | Vendor Connections card | Vendor credentials bind to a specific restaurant; cross-location reuse breaks idempotency. | "Connect a vendor at the location level" inline help + scope picker disabled above location |
| My Account is user-scoped, not business-scoped | All four cards | Account identity is the user, not the business. Hierarchy doesn't apply. | No scope picker on My Account |
| Default Role catalog edit is global | Admin Console "Default Roles" | Catalog is a global F&F asset; per-business edit would fragment. | Banner "F&F Admin: Default Role Catalog" + blast-radius preview on save |

Any new carve-out introduced after this wave must add a row here AND update the
relevant contract doc before merge.

## UX Writing And Naming Conventions

- "Default" badge for catalog-driven roles. Read-only.
- "Custom" pill for operator-scoped roles. Inline actions menu.
- "Inherited from <scope>" for resolved settings carrying upstream value.
- "Set at this scope" for locally-configured settings.
- "Overridden at <child>" when a parent scope sees diverging child values.
- "Mixed — N use X, M use Y. View by location." for parent-scope indeterminate.
- "F&F Admin" banner only on global catalog-edit surfaces.
- Never expose raw `role_key`, `permission_key`, or `org_unit_path` in primary
  scan. All belong in a "Show details" toggle or a tooltip.
- 24-hour grace window for sensitive account changes (2FA removal). Cancel CTA
  always more prominent than destructive option in grace state.
- Per addendum C1 + R1 #1/#2/#5/#6/#8: one step-up modal, one badge style, one
  audit-link footer, one inheritance-tree component across the whole feature
  lane.

## What Is Out of Scope For Lane B

- Proxy decomposition, perf, soak harness work → Lane A.
- Email pipeline scaffolding sweep → Lane C.
- Mobile parity (notification badge, blended wage mix mobile read-only,
  hierarchy breadcrumbs on mobile) → Lane C.
- Barrio surface activation (only the schema + dormant tab seam ships here).
- Phase 11A.3 advisor UI, 11A.11 cross-vendor enrichment, 11B/12 AI work — all
  paused per `project_phase_pause_2026_05_03`.
