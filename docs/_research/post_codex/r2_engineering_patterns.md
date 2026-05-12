# r2 — Engineering Patterns Brief (Post-Codex Wave)

> Status: research draft, 2026-05-12
> Author: research agent (worktree `nifty-clarke-d3ec25`)
> Companion to: `docs/_decisions/post_codex_wave_decisions_2026-05-12.md` (8 locked decisions)
> Stack context: Flutter mobile + Flutter Web (admin + operator) + Dart proxy on Cloud Run + Postgres 16 (AGE, pgvector, pg_diskann, pg_cron, pg_partman, pgcrypto) + Firebase Auth + SendGrid. No `pgmq`. RLS-ready operator-scoped tables. Hash-chained `audit_logs` (SHA-256, daily Azure Blob anchor, per-operator/day partitioning). `OperatorScopedRepository<T>` is the primary defense; RLS is backup. Proxy writes are idempotent (`proxy_requests` UNIQUE key).
> Cap: 800 lines.

## How to read this brief

For each of the 7 topics:

1. **Decision pointer** — which locked decision (from the decisions doc) it validates or pushes back on.
2. **Reference implementations** — 1-2 real systems with doc links.
3. **What our stack inherits cleanly** — what maps onto Phase 7.55 with no friction.
4. **Gotchas** — concrete risks given our guardrails.
5. **Recommendation** — keep / refine / push back, plus implementation cost on a 1-day / 1-week / 1-month scale.

Sources are listed at the end. Inline citations use shortcodes `[S#]` so the body stays readable.

---

## Topic 1 — ReBAC role + permission modeling

### Decision pointer

Validates **decision #3** (immutable role UUID + display slug). Also touches #2 (default-role catalog, see Topic 6) and #7 (permission cascade, see Topic 7).

### Reference implementations

- **OpenFGA** (CNCF, Zanzibar-derived, Auth0 lineage). Authorization models are *immutable*; every write creates a new versioned model ID `[S1, S5]`.
- **SpiceDB** (Authzed, Zanzibar-derived). Schema language has strict type-safety: a relation cannot be removed while any tuple references it `[S2]`. Permissions are computed-on-read from relationships, so renaming/recomputing a permission is a schema-only change with no data backfill `[S2, S11]`.
- **Oso Cloud / Polar**. Policy-engine model (declarative rules, not a Zanzibar relationship store). Reads tenant data directly from app DB; supports built-in roles with org/sub-org hierarchies `[S3, S12]`.

### Our shape

`operator → org_unit → location` hierarchy, ~99 product-categorized keys (`product.*`, `forgeflow.*`, `barrio.*`, `team.*`, `integrations.*`, etc.), Default vs Custom roles, MFA-gated subset of keys (frozen at code level). Permission keys are app-defined; operators choose which keys a custom role grants/denies — they cannot invent keys (see `docs/contracts/auth_permission_key_catalog.md`).

### What maps cleanly

- **Zanzibar shape works for our hierarchy**. `operator#member@user`, `location#manager@user`, `org_unit#parent@org_unit` reads naturally. Both OpenFGA and SpiceDB handle the parent-pointer cascade out of the box `[S5, S11]`.
- **Immutable role UUID + display slug (decision #3) is the industry default**. OpenFGA tuples reference relations by name string, but the *authorization model* is versioned by UUID so the *meaning* of "manager" is locked to a specific schema version `[S1]`. Renaming a Default role's display label = update the `name` column on the role row keyed by UUID; tuples never touch the name. **Validated — keep decision #3 as-is.**
- **MFA-required key set freezing at code level** matches our `lib/auth/permission_keys.dart` + migration seed approach. Both SpiceDB and OpenFGA recommend treating schema updates "as though they were database migrations" `[S2]`.

### Gotchas

1. **Role rename ≠ role merge.** OpenFGA's documented rename pattern is a 4-phase sequence: add backward-compat alias → write to both → migrate tuples → drop alias `[S4]`. For us, since we keep role identity via UUID, a *display rename* is a single-row UPDATE on `roles.display_name` and needs no tuple migration. **This is precisely the value of decision #3.**
2. **OpenFGA single-layer hierarchy constraint.** OpenFGA does not allow a permission to reference a relation more than one layer deep `[S5]`. Our `operator → org_unit → location` is 2-3 layers; if we ever adopt a Zanzibar engine we'd flatten via computed_userset (each location stores both its immediate parent and a denormalized `operator_id`). This matches what we already do with `(operator_id, location_id)` on every fact table.
3. **No Zanzibar engine today, and don't add one for v1.** We have a code-level permission catalog + Postgres role/permission tables + `OperatorScopedRepository`. Adopting OpenFGA/SpiceDB would add a second source of truth that must be kept in sync with the SQL catalog. The cost-benefit only flips if we (a) need ReBAC for object-level sharing (e.g., "this specific shift can be edited by these two users"), or (b) hit Zanzibar-class scale (10⁹ tuples). Neither applies at launch.
4. **Custom roles are bounded sets, not relationship grants.** OpenFGA's "custom roles" pattern stores role definitions as tuples (`role:rolename#assignee@user`) `[S13]`. We instead store `(role_id, permission_key)` in a join table. This is simpler and works because the universe of keys is fixed. **Validated — no change.**

### Recommendation

**Keep current Postgres-native approach + decision #3 as-is.** Push back on any future suggestion to introduce OpenFGA/SpiceDB before v1: our shape doesn't need ReBAC's relationship algebra, and the operational cost (second write path, replication, eventual consistency) is incompatible with our hash-chained `audit_logs` invariant (writes must be atomic with the audited change — see Topic 4).

**Cost estimate:**
- Decision #3 as written: **1-day** (add UUID + slug columns to `roles`, migrate). Already partly implemented in 9.6.
- Future ReBAC adoption (not recommended for v1): **1-month** + ongoing dual-write maintenance.

---

## Topic 2 — Schema versioning + migration system

### Decision pointer

Validates the existing migration approach (`db/migrations/*.sql` + `tool/migration_drift_scanner.dart` + `tool/migration_cutoff_lint.dart`).

### Reference implementations

- **GitLab** — formalizes the **expand-contract** pattern across 2-3 releases for every destructive change `[S6]`. Column rename: release M concurrently creates new column + triggers sync; release M (post-deploy) finalizes; release M+1 drops the ignore rule. Column drop is a 3-release sequence (ignore → drop → cleanup) to defeat ActiveRecord's schema cache `[S6]`.
- **Stripe** — date-stamped API versions, per-account pinning, transformation modules walked backward in time `[S7, S8]`. Schema changes are *internal*; clients see a stable contract per their pinned version.
- **Shopify Vitess** — sharded MySQL; multi-week migrations on multi-TB tables; add-column-then-backfill is mandatory `[S14]`.

### Our shape

Single Postgres cluster (Azure Flexible Server, Canada Central, PG 16). Operator-scoped tables carry `(operator_id, location_id)`. No per-tenant schema branching at the v1 launch (decision #4 — single schema). Demo and prod share the same tables. `pg_partman` partitions `audit_logs` per-operator/day. `tool/migration_drift_scanner.dart` already exists and is run after `db/migrations/*.sql` changes (per `CLAUDE.md`).

### What maps cleanly

- **Expand-contract is the right discipline regardless of single vs per-tenant schema.** Even in a shared-schema model, a hot table with billions of rows of `audit_logs` cannot tolerate a synchronous `ALTER TABLE ... ADD COLUMN NOT NULL DEFAULT ...` followed by a backfill. GitLab's pattern (add nullable column → backfill in batches → add NOT NULL constraint → drop old column in a later release) is directly portable `[S6]`.
- **`pg_partman` is friendly to expand-contract** because per-day partitions limit the blast radius of a backfill: we can backfill old partitions concurrently or skip them and only enforce constraint on `> cutoff_date` partitions.
- **Stripe's account-pinning idea = our `Stripe-Version`-style proxy header.** Not relevant today (we control both proxy and client), but the *spirit* — never break a client mid-deploy — should govern Flutter app upgrade behavior. Proxy already supports `/v1` and `/v2` per `CLAUDE.md`; this is the same idea minus per-account pinning.

### Gotchas

1. **Per-operator migration safety is not a current concern but will become one.** As long as we use a single schema with `operator_id` discriminators, every migration is a *single* schema change. The moment we add per-operator schemas (extracted in HP #4 "RLS-ready" — schema-level multi-tenancy is *not* the choice; RLS + discriminator is), we inherit the Citus/Flyway pain `[S15]`. **Validated decision #4: no per-operator schemas.**
2. **`tool/migration_drift_scanner.dart` covers structural drift, not migration *staging*.** It will catch a missing migration file or a schema mismatch, but it won't tell you that a NOT NULL constraint added in release M will brick all running app instances on release M-1. We need an explicit *post-deployment migration* convention (a separate `db/migrations/post_deploy/` directory) before the next destructive change ships.
3. **Hash-chained `audit_logs` is allergic to in-place row mutation.** Any migration that rewrites old audit rows (e.g., backfilling a new column with non-default data) invalidates the SHA-256 chain. Treat the chain hash columns (`row_hash`, `prev_row_hash`) as immutable; any new column must be NULL in old rows and the chain recomputation rule must explicitly skip the new column for pre-cutoff rows. **This is a hard guardrail — add it to the contract.**
4. **No `pgmq`.** Online backfills should use `FOR UPDATE SKIP LOCKED` (per our scalability lock — `docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md`) or Cloud Tasks, never an in-DB queue.
5. **Rollback-safety.** Per GitLab: column drops are "destructive operations that can't be rolled back easily" `[S6]`. The post-deploy migration must defer the drop by ≥2 releases.

### Recommendation

**Keep `tool/migration_drift_scanner.dart`. Add three things before the next destructive migration:**

1. A `db/migrations/post_deploy/` convention with a separate CI step (per GitLab).
2. A `--require-expand-contract` flag on the drift scanner that fails CI if a single migration combines schema add + backfill + constraint tighten.
3. A guardrail in `migration_cutoff_lint.dart` that flags any `UPDATE audit_logs SET ...` outside an explicit allowlist (chain integrity).

**Cost estimate:**
- All three items above: **1-week** total.
- Per-operator schema migration system (not needed at v1): **1-month** if we ever adopt schema-per-tenant.

---

## Topic 3 — Mobile → Web JWT handoff with fresh-MFA gating

### Decision pointer

Validates **decision #5** (JWT reuse via deep link). Adds the required guardrails.

### Reference implementations

- **RFC 9470 — OAuth 2.0 Step Up Authentication Challenge Protocol** `[S9]`. Defines the `WWW-Authenticate` challenge with `acr_values` + `max_age` and the `insufficient_user_authentication` error. Resource server returns 401 with the challenge; client re-authenticates and retries with a fresher token.
- **OWASP — Broken Authentication** `[S10]`. Specifically warns about authentication flows that include one-click deep-link auth and demands rigorous validation/sanitization of all data entering via deep links.
- **OpenID Connect — JARM (JWT-Secured Authorization Response Mode)** `[S16]`. Distinguishes `query.jwt` (token in query string, suitable for code flow only) from `fragment.jwt` (token in URL fragment, more secure — never sent to server, not logged in standard access logs).

### Our shape

User authenticates in Flutter mobile app via Firebase Auth → operator clicks a "open in web admin" link → mobile generates a deep link to `app.forgeflow.app/handoff?...` → web admin reads token, redirects to landing page.

### What maps cleanly

- **JWT handoff via short-lived single-use redemption code is the standard.** Don't pass the JWT itself in the URL. Mint a one-time `handoff_code` (random 256-bit, server-stored with `expires_at = now() + 60s` and `consumed_at` nullable). Web admin POSTs the code to `/v1/auth/handoff/redeem` → proxy validates, marks consumed, returns the JWT in the response body. This matches OAuth's authorization-code flow `[S16]`.
- **Fragment, not query, if we ever DO pass a token in URL.** Fragments are not sent over the wire and not logged by standard access logs `[S16]`. But: SendGrid email logs, mobile OS share dialogs, and screen recording still leak fragments. **Strongly prefer the redemption-code pattern.**
- **Fresh-MFA gating is RFC 9470, not bespoke.** When the web admin lands on a sensitive route (Default Role Catalog edit, Vendor Credential management, Audit Log export), the proxy returns 401 with `WWW-Authenticate: Bearer error="insufficient_user_authentication", acr_values="urn:mfa", max_age=300` `[S9]`. Web client redirects to MFA step-up flow.

### Gotchas (against decision #5 as written)

1. **Pushback on naive "JWT reuse via deep link".** If decision #5 means "stuff the JWT into the deep link URL", that's an OWASP-flagged anti-pattern `[S10]`. Reasons:
    - **Referer leak**: clicking any external link from the handoff landing page leaks the URL (incl. fragment in some browsers + headers) to the destination via `Referer`. Mitigation: `Referrer-Policy: no-referrer` on the landing page.
    - **Browser history**: full URL persists in history. Even with fragment, `chrome://history` shows it.
    - **Server logs**: query-string tokens hit Cloud Run access logs, Cloudflare/Azure WAF logs, and any reverse proxy log. *Even though we control them*, log retention may exceed token TTL.
    - **Shared links**: operators forward the link assuming it's harmless.
    - **Email rendering**: if the link is ever in a SendGrid email (e.g., "click to continue in web"), email gateways and the recipient's inbox provider see the JWT.
2. **No-iframe is non-negotiable.** Set `Content-Security-Policy: frame-ancestors 'none'` on every sensitive page and ensure `Referrer-Policy: no-referrer` on the handoff redemption endpoint `[S17]`. X-Frame-Options is deprecated for new code (modern browsers prefer CSP frame-ancestors) but should still be sent for older clients.
3. **HTTPS-only enforcement.** HSTS with `includeSubDomains; preload`. Reject the redemption code over HTTP (Cloud Run already enforces this; verify).
4. **Single-use code, short TTL.** 60s TTL, atomic consume (`UPDATE handoff_codes SET consumed_at = now() WHERE code = $1 AND consumed_at IS NULL RETURNING ...`). Replay returns 410 Gone with a structured error.
5. **Observability for handoff redemption.** Every handoff event = a row in `auth_events_audit` with actor, source device fingerprint, destination IP, success/fail. Failed redemptions trigger an `auth.handoff.failed` metric and a Sentry breadcrumb. Per-operator rate limit (e.g., 10 handoffs/hour) on the `/handoff/redeem` endpoint, served by the existing proxy idempotency / rate-limit layer.
6. **Fresh-MFA gating on landing.** Per RFC 9470, the redemption endpoint MUST inspect the source token's `auth_time` claim. If `now - auth_time > 5min` and the target route requires step-up, return 401 with the `insufficient_user_authentication` challenge so the web client triggers MFA before redeeming `[S9]`. **This is the missing rule in decision #5 as currently stated.**

### Recommendation

**Refine decision #5: replace "JWT reuse via deep link" with "redemption-code handoff with fresh-MFA gating per RFC 9470".** The user-visible behavior is identical (operator clicks a link on mobile, lands authenticated in web); the security posture jumps from "OWASP-flagged" to "industry-standard step-up".

**Cost estimate:**
- Redemption-code endpoint + `handoff_codes` table + Flutter Web client: **1-week**.
- RFC 9470 challenge integration on sensitive routes: **1-week** (incremental; tag routes via permission keys with `requires_fresh_mfa = true`).

---

## Topic 4 — Denormalize-on-read vs read-side join for hierarchy filtering

### Decision pointer

Validates **decision #8** (read-side join).

### Reference implementations

- **AWS CloudTrail Lake** — immutable event store with read-side filtering against attributes like account ID, region, event source `[S18]`. Hash-chained digest files (SHA-256, RSA-signed, hourly) are *separate* from the queryable event table; the query layer never touches the chain `[S19]`.
- **Stripe events** — append-only event stream; clients filter by `type`, `account`, `created` at read time. Stripe specifically advises *not* embedding tenant-relationship metadata in the event row beyond IDs, and resolving display names at read time `[S7]`.
- **GCP Audit Logs** — write-once log entries with structured fields (`resource.type`, `resource.labels`, `protoPayload.authenticationInfo`); BigQuery-backed filtering at read time. No denormalized display labels in the immutable row.

### Our shape

Hash-chained `audit_logs` with `(operator_id, location_id, org_unit_id?, actor_user_id, action, hash, prev_hash, ...)`. Partitioned per-operator/day via `pg_partman`. Daily anchor to Azure Blob. Reads filtered by hierarchy: "all rows in operator X under org_unit Y for time range Z".

### What maps cleanly

- **Decision #8 (read-side join) is industry-correct for immutable audit history.** All three reference systems do exactly this `[S18, S19]`. Reasons:
    - **Chain integrity**: any denormalized field (e.g., `location_name`) in the audit row becomes part of the hash. If the operator renames the location later, the chain either (a) preserves the stale name forever (operator-confusing), or (b) requires a chain rewrite (defeats tamper-evidence).
    - **Hierarchy mutation**: org_units split, merge, get reparented. Denormalized hierarchy = a permanent lie in the log. Read-side join against the current hierarchy is the only honest answer.
    - **Storage**: `audit_logs` is the highest-volume table. Denormalization multiplies bytes per row.
- **Per-operator partitioning makes hierarchy filtering cheap.** Per the tamper-evident architecture guidance `[S20]`: "If you expect to partition audit data, keep each chain fully contained within one partition by using the same partition key as the stream key (for example, tenant id)." We already partition per-operator/day. Adding a `WHERE location_id IN (...descendant location IDs from current hierarchy...)` predicate is a B-tree index seek inside the daily partition (we already require the lead-with-operator-id index discipline).

### Gotchas

1. **Closure table vs `ltree` for the hierarchy lookup.** Read-side join still needs to resolve "all descendants of org_unit Y" cheaply. Options:
    - `ltree` with GiST index — fastest for ancestor/descendant queries; size-limited for very deep trees `[S21]`. Our tree is ≤4 levels (operator → org_unit → org_unit → location); fine.
    - Closure table — explicit (ancestor, descendant) rows. More writes on hierarchy edit; trivial reads `[S22]`.
    - Recursive CTE — slowest; only use when hierarchy is small or rarely queried.
  **Recommended: `ltree` on the hierarchy tables, plain B-tree index on `(operator_id, location_id, occurred_at)` on `audit_logs`.** The join then becomes `WHERE location_id = ANY (SELECT location_id FROM locations WHERE path <@ <ancestor_path>)`.
2. **Don't denormalize, but DO cache.** A read-side query that recomputes the descendant set on every audit query is wasteful. Cache the descendant set per (operator_id, org_unit_id) in a materialized view refreshed on hierarchy edits, or in app memory via the existing `OperatorScopedRepository`. **Cache invalidation = invalidate on hierarchy edit (rare event).**
3. **Display names in the read response are fine to inject at the application layer.** The audit row stores IDs; the JSON the operator sees joins to current `locations.display_name`. If the location later renames, the audit row is unchanged but the display reflects the rename. This is the expected user-visible behavior (`audit_logs` is the source of *what happened*, not *what it was called*).
4. **Cross-operator views are a separate concern.** F&F support cross-tenant access via `forge_admin BYPASSRLS` is audited (`app.bypass_rls_audit = 'system:<reason>'`). Read-side join still works — the support UI joins against the operator's *current* hierarchy at the time of view, not at the time of the audited event.

### Recommendation

**Keep decision #8 (read-side join). Codify the gotchas:**

- `ltree` (or closure table — pick one and lock it) on `org_units` + `locations`.
- B-tree on `audit_logs (operator_id, location_id, occurred_at DESC)` — already mandated by the "fact-table B-tree leads with operator_id" CI lint.
- Materialized-view or in-app cache of descendant sets, invalidated on hierarchy edit.
- Display names resolved at JSON-response time, never stored in the audit row.

**Cost estimate:**
- `ltree` migration + descendant-set helper + repository extension: **1-week**.
- Materialized view + invalidation hook: **1-day** added to the above.

---

## Topic 5 — Editable vendor-applicability list schema

### Decision pointer

(Not directly locked in the 8 decisions, but referenced as a near-term need for "which vendors does setting X apply to" — covers / wage authority / polling interval.)

### Reference implementations

- **Hybrid normalized + JSONB** is the recommended Postgres pattern per multiple sources `[S23, S24]`. Core relational structure for the dimensions you query against; JSONB column for the flexible remainder.
- **EAV is an anti-pattern in Postgres** per Cybertec, EDB, and others — slower (3x storage, 1.3x slower reads even with indexes), harder to query, and the "infinite flexibility" pitch rarely matches real attribute volatility `[S24, S25]`.

### Our shape

Three known surfaces today:
1. **Covers** — which POS vendors does the "include `dine_in` covers only" setting apply to?
2. **Wage authority** — which payroll vendors does the "wage source = job code" rule apply to?
3. **Polling interval** — which integrations does the "1h vs 4h vs 24h" polling override apply to?

Operators (or F&F admins, depending on the surface) edit which vendors are in scope.

### Recommendation: one table with discriminator

**Schema sketch:**

```sql
CREATE TABLE setting_vendor_applicability (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operator_id     UUID NOT NULL,                  -- NULL for global defaults, NOT NULL for per-operator overrides
  setting_kind    TEXT NOT NULL,                  -- 'covers' | 'wage_authority' | 'polling_interval'
  setting_key     TEXT NOT NULL,                  -- e.g., 'dine_in_only', 'job_code_authoritative'
  vendor_slug     TEXT NOT NULL,                  -- 'toast', 'square', 'gusto'
  enabled         BOOLEAN NOT NULL DEFAULT true,
  metadata        JSONB NOT NULL DEFAULT '{}',    -- per-vendor knobs (e.g., polling_seconds_override)
  effective_from  TIMESTAMPTZ NOT NULL DEFAULT now(),
  effective_until TIMESTAMPTZ,                    -- NULL = currently active
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by      UUID NOT NULL,
  UNIQUE (operator_id, setting_kind, setting_key, vendor_slug, effective_from)
);

CREATE INDEX setting_vendor_applicability_lookup_idx
  ON setting_vendor_applicability (operator_id, setting_kind, setting_key)
  WHERE effective_until IS NULL;
```

### Why one table + discriminator (not three)

- **Single audit pattern, single repository, single RLS policy.** Three tables = three of everything.
- **`setting_kind` discriminator** keeps the SQL small and lets you add `polling_v2`, `cover_breakdown_v2`, etc., without DDL.
- **`metadata JSONB`** covers vendor-specific knobs without forcing every consumer to read columns it doesn't care about. Hybrid pattern per Postgres guidance `[S23]`.
- **Effective-from/until temporal columns** keep change history without a separate audit table. Reads filter `effective_until IS NULL` for current state; history reads filter by time range. This pattern matches how we already handle `target_cycles`, `weekly_plans`.

### Gotchas

1. **`vendor_slug` is a foreign key target.** Source it from `integration_vendor_catalog.slug` (existing Phase 8 catalog). Reject unknown slugs at the application layer; DB-level FK only if the vendor catalog is fully materialized in Postgres (it is, per Phase 8.0).
2. **JSONB schema discipline.** Each `setting_kind` should have a documented JSON schema in `lib/services/settings/applicability_metadata_schemas.dart` and a validator. Otherwise you get the JSONB-as-EAV anti-pattern `[S24]`.
3. **RLS-ready.** Lead with `operator_id`. Use the wrapper functions (`app_current_operator()`), not bare `current_setting()`. Per `docs/contracts/hardening_rls_and_repository_pattern_contract.md`.
4. **Don't lose change history.** The effective-from/until columns + an INSERT-only repository (no UPDATE/DELETE; "ending" a row = update `effective_until`) preserves auditability. Wire writes through the hash-chained `audit_logs` writer (same transaction).

### Cost estimate

- Table + repository + JSONB validator + RLS policy: **1-week**.

---

## Topic 6 — Default Role catalog publish/sync

### Decision pointer

Validates **decision #2** (F&F admin edits the catalog → all businesses inherit globally).

### Reference implementations

- **OPA bundle distribution** — control plane publishes a versioned policy bundle; agents pull on a poll interval (default 60s) and apply atomically `[S26]`.
- **AWS AppConfig** — push-style (with rollback triggers, canary, schema validation) for SaaS tenant configurations `[S27]`.
- **LaunchDarkly / similar feature-flag systems** — pull at SDK init + streaming updates; tenant-scoped overrides `[S27]`.

### Pull (resolve at read time) vs Push (every business gets a copy on edit)

**Recommendation: Pull, with a catalog version pointer per business.**

Why:
1. **Push duplicates ~99 keys × N businesses on every edit.** With per-business copies, a Default Role change = N writes, N audit rows, N consistency windows. At 50 businesses today and 5000 at scale, the cost is real.
2. **Pull is what every policy/config system actually does** `[S26, S27]`. Even "push" systems (AppConfig, LaunchDarkly) are really "pull from a versioned source with cache invalidation".
3. **Versioned catalog is the canonical pattern.** Treat the Default Role catalog like an OPA bundle: `default_role_catalog_versions (version_id, published_at, published_by, json_payload, sha256)`. Businesses don't get a copy — they get a pointer (`businesses.default_role_catalog_version_id`, nullable; NULL = always latest).
4. **Custom roles are per-business and don't inherit.** They live in `roles` keyed by `(operator_id, role_uuid)` and never reference catalog versions.

### Schema sketch

```sql
CREATE TABLE default_role_catalog_versions (
  version_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  version_label   TEXT NOT NULL UNIQUE,         -- e.g., '2026-05-12-v1'
  published_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  published_by    UUID NOT NULL,                -- F&F admin user
  payload         JSONB NOT NULL,               -- {roles: [{uuid, slug, name, permission_keys: [...]}, ...]}
  payload_sha256  TEXT NOT NULL,
  changelog       TEXT
);

ALTER TABLE businesses ADD COLUMN default_role_catalog_version_id UUID
  REFERENCES default_role_catalog_versions(version_id);
  -- NULL = follow latest; set = pinned (for businesses that opt out of auto-upgrade)
```

### Pull-time resolution

```sql
-- Pseudo: resolve effective catalog for a business
SELECT payload
FROM default_role_catalog_versions
WHERE version_id = COALESCE(
  (SELECT default_role_catalog_version_id FROM businesses WHERE id = $1),
  (SELECT version_id FROM default_role_catalog_versions ORDER BY published_at DESC LIMIT 1)
);
```

App-layer cache by `version_id` (immutable per version, so cache is forever valid). Invalidate the business→version pointer cache on business edit only.

### Audit trail

Every publish writes:
1. A row to `default_role_catalog_versions` (immutable).
2. A row to `audit_logs` with `actor = F&F admin`, `action = 'default_role_catalog.publish'`, `payload_sha256` in the body.
3. The hash chain in `audit_logs` provides tamper-evidence.

Businesses that auto-follow latest get an implicit upgrade visible via the published_at timestamp on the resolved version; businesses that have pinned a specific version stay put. Pinned-version overrides should be rare and require F&F support intervention.

### Gotchas

1. **Backward compatibility on permission key removal.** If a published catalog version removes a key that a *Custom* role references, the custom role becomes broken. Rule: the catalog can only *add* keys (matches the immutability discipline in `lib/auth/permission_keys.dart`). To remove a key, deprecate first (mark `deprecated_at`), filter out at read time, drop in a much later release per GitLab expand-contract `[S6]`.
2. **MFA-required set freezing at code level (auth_permission_key_catalog.md) is upstream of the catalog.** The published catalog can reference only keys that exist in `lib/auth/permission_keys.dart` at the time of publish. A CI check on publish (server-side) enforces this.
3. **Demo and prod share the same catalog.** Per HP #2, no `kDemoMode` branch on catalog reads.

### Cost estimate

- Versioned catalog table + publish endpoint + pull-time resolution + cache: **1-week**.
- Pinning UI (if needed at all for v1): **1-day** added.

---

## Topic 7 — Permission dependency cascade engine

### Decision pointer

Validates the "selecting `forgeflow.benchmark.edit` auto-includes `product.forgeflow.access`" behavior referenced in decision #6 (or close to it).

### Reference implementations

- **OpenFGA computed permissions** — `define benchmark_edit: [user] or product_forgeflow_access` style; the permission is *computed* from the relations at read time. No data backfill on dependency edit; just schema update `[S5, S28]`.
- **SpiceDB permissions** — same: a permission is a *computed* function of relations, not a stored fact. Renaming or reshaping the permission requires zero data migration `[S2, S11]`.
- **Casbin RBAC role hierarchy** — explicit `g, child_role, parent_role` grouping rules; `GetImplicitPermissionsForUser` walks the hierarchy `[S29]`.
- **Oso Polar** — declarative rules: `has_permission(actor, "benchmark.edit", resource) if has_permission(actor, "product.forgeflow.access", resource);` `[S30]`.

### Our shape

Permission keys are flat strings in `lib/auth/permission_keys.dart`. Dependencies between keys (e.g., "edit implies view", "feature implies product access") are *not* explicit in the catalog today — they're enforced implicitly because operators can't enter the product without the `product.*` key.

### Two paths to make dependencies explicit

**Path A — UI-side resolution (recommended for v1).**

Store the dependency graph in `lib/auth/permission_dependencies.dart` (a `const Map<String, List<String>> kImplies = { ... }`). When a Role Editor in the admin UI selects `forgeflow.benchmark.edit`, the UI walks the map and auto-checks the transitive closure. The DB stores the *expanded* set of keys (no implicit at storage layer).

Pros: zero runtime overhead, fully deterministic, deps are version-controlled with the code.
Cons: changing a dep rule requires a code release. (Same property as the frozen catalog — feature, not bug.)

**Path B — Write-time DB-side cascade.**

A `permission_implies (parent_key, child_key)` table. A trigger or repository hook expands selected keys on role save. Same end result as Path A but allows F&F admin to add deps without a code release.

Pros: dynamic.
Cons: another source of truth that must stay in sync with `lib/auth/permission_keys.dart`; another lint to write; another audit surface.

### Recommendation

**Path A (UI-side resolution + expanded storage).** Reasons:

1. **The keys are already code-defined**, so deps following the same release cadence is consistent.
2. **No graph traversal at runtime** — every permission check is a single membership test against the role's expanded key set. No N+1 walks, no recursive CTE.
3. **Audit is honest**: the role row stores exactly the keys the admin saw selected (after the cascade). The audit log row stores the deltas. No need to re-resolve dependencies retroactively when reading old audit entries.
4. **Matches how OpenFGA computes vs SpiceDB stores**: their *computed* permissions are dynamic, but *we* don't have the read-time graph evaluator they have — we have `role_permissions (role_id, permission_key)`. Storing the expanded set is the right shape for our storage.

If dynamic dependency rules become necessary (rare — implies vendor onboarding scenarios), Path B can be added later via a one-time backfill, without breaking Path A.

### Gotchas

1. **Cascade must be transitive.** If `benchmark.edit → benchmark.view → product.forgeflow.access`, selecting `benchmark.edit` must check all three. Implement as a topological walk (DAG; reject cycles in `permission_dependencies.dart` with a build-time assertion).
2. **Removing a key must be cascade-aware.** If admin un-checks `product.forgeflow.access`, the UI should warn that `benchmark.edit` and `benchmark.view` will also be un-checked (or grey them out as locked-on while the parent is selected, depending on UX choice).
3. **Custom Role vs Default Role symmetry.** Both use the same cascade. The cascade is a property of the permission-key universe, not of a particular role.
4. **MFA flag interaction.** The MFA-required set is a *per-key* property, not a cascade. Selecting a parent key never implicitly upgrades a child's MFA requirement and vice versa. Document this in the auth permission catalog.

### Cost estimate

- `permission_dependencies.dart` + UI cascade + topo-sort builder + build-time cycle check: **1-week**.
- Path B (dynamic): **1-month**, not recommended for v1.

---

## Cross-cutting validation against the 8 locked decisions

| Decision | Topic | Verdict | Refinement |
|---|---|---|---|
| #1 (assumed: single-schema multi-tenant w/ `(operator_id, location_id)`) | 2 | Validated | None — `pgmq` already excluded |
| #2 (F&F admin edits Default Role Catalog, businesses inherit globally) | 6 | Validated | Implement as Pull + versioned catalog, not Push-to-every-business |
| #3 (immutable role UUID + display slug) | 1 | Validated | None — matches OpenFGA model-versioning + tuple-key-by-name pattern |
| #4 (no per-operator schemas — assumed) | 2 | Validated | None |
| #5 (JWT reuse via deep link for mobile→web) | 3 | **Refine** | Replace with redemption-code + RFC 9470 step-up. As written, decision #5 is OWASP-flagged. |
| #6 (assumed: permission dependency cascade) | 7 | Validated | Path A (UI-side resolution, expanded storage) |
| #7 (assumed: single hash-chained audit log shared across operators with RLS) | 4 | Validated | None — chain integrity rules now codified |
| #8 (read-side join for hierarchy filtering) | 4 | Validated | Add `ltree` (or closure table) + descendant-set cache |

**One decision needs a substantive rewrite (#5). The other seven are validated by industry practice; refinements are codification of guardrails the references make explicit.**

---

## Total implementation cost estimate (1-day / 1-week / 1-month buckets)

| Item | Bucket |
|---|---|
| Topic 1 — Role UUID + slug as locked | 1-day |
| Topic 2 — Post-deploy migration convention + expand-contract lint + audit-chain UPDATE guardrail | 1-week |
| Topic 3 — Redemption-code handoff + RFC 9470 step-up integration | 1-week |
| Topic 4 — `ltree` + descendant cache + B-tree audit index (existing) | 1-week |
| Topic 5 — Vendor-applicability table + JSONB validator + RLS | 1-week |
| Topic 6 — Versioned catalog + pull-time resolution + cache | 1-week |
| Topic 7 — Permission dependency cascade (Path A) | 1-week |

**Total v1 cost across all 7 topics: ~6 engineer-weeks, sequential.** Several can run in parallel (Topic 1 + 5 + 6 + 7 are independent; Topics 2/3/4 touch shared infra).

---

## Sources

- [S1] [OpenFGA — Concepts (versioned authorization models)](https://openfga.dev/docs/concepts)
- [S2] [Authzed — Migrating a Schema in SpiceDB](https://authzed.com/docs/spicedb/modeling/migrating-schema)
- [S3] [Oso — Multitenant Roles](https://www.osohq.com/docs/modeling-in-polar/role-based-access-control-rbac/roles)
- [S4] [OpenFGA — Migrating Relations](https://openfga.dev/docs/modeling/migrating/migrating-relations)
- [S5] [OpenFGA — Roles and Permissions](https://openfga.dev/docs/modeling/roles-and-permissions)
- [S6] [GitLab Docs — Avoiding downtime in migrations](https://docs.gitlab.com/development/database/avoiding_downtime_in_migrations/)
- [S7] [Stripe blog — APIs as infrastructure: future-proofing Stripe with versioning](https://stripe.com/blog/api-versioning)
- [S8] [Stripe Docs — Versioning](https://docs.stripe.com/api/versioning)
- [S9] [RFC 9470 — OAuth 2.0 Step Up Authentication Challenge Protocol](https://datatracker.ietf.org/doc/rfc9470/)
- [S10] [OWASP API Security Top 10 — API2:2023 Broken Authentication](https://owasp.org/API-Security/editions/2023/en/0xa2-broken-authentication/)
- [S11] [Authzed Blog — Online Schema Migrations in SpiceDB](https://authzed.com/blog/online-schema-migrations)
- [S12] [Oso — Introducing Built-in Roles](https://www.osohq.com/post/introducing-builtin-roles)
- [S13] [OpenFGA — Custom Roles](https://openfga.dev/docs/modeling/custom-roles)
- [S14] [Shopify Engineering — Horizontally scaling the Rails backend of Shop app with Vitess](https://shopify.engineering/horizontally-scaling-the-rails-backend-of-shop-app-with-vitess)
- [S15] [Citus Docs — Multi-Tenant Schema Migration](https://docs.citusdata.com/en/v7.4/develop/migration_mt_schema.html)
- [S16] [OpenID — JWT Secured Authorization Response Mode for OAuth 2.0 (JARM)](https://openid.net/specs/oauth-v2-jarm.html)
- [S17] [OWASP — Clickjacking Defense Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Clickjacking_Defense_Cheat_Sheet.html)
- [S18] [AWS Docs — What Is AWS CloudTrail?](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-user-guide.html)
- [S19] [Hoop.dev — Immutable Audit Logs and CloudTrail Query Runbooks](https://hoop.dev/blog/immutable-audit-logs-and-cloudtrail-query-runbooks-for-fast-reliable-investigations/)
- [S20] [Veritaschain (DEV) — Building a Tamper-Evident Audit Log with SHA-256 Hash Chains](https://dev.to/veritaschain/building-a-tamper-evident-audit-log-with-sha-256-hash-chains-zero-dependencies-h0b)
- [S21] [PostgreSQL Docs — F.22. ltree](https://www.postgresql.org/docs/current/ltree.html)
- [S22] [Ackee blog — Hierarchical models in PostgreSQL](https://www.ackee.agency/blog/hierarchical-models-in-postgresql)
- [S23] [Raz Samuel — PostgreSQL JSONB vs. EAV: Which is Better for Storing Dynamic Data](https://www.razsamuel.com/postgresql-jsonb-vs-eav-dynamic-data/)
- [S24] [Cybertec — Entity-attribute-value (EAV) design in PostgreSQL — don't do it!](https://www.cybertec-postgresql.com/en/entity-attribute-value-eav-design-in-postgresql-dont-do-it/)
- [S25] [EDB blog — PostgreSQL anti-patterns: Unnecessary json/hstore dynamic columns](https://www.enterprisedb.com/blog/postgresql-anti-patterns-unnecessary-jsonhstore-dynamic-columns)
- [S26] [AWS — Using AWS AppConfig to Manage Multi-Tenant SaaS Configurations](https://aws.amazon.com/blogs/mt/using-aws-appconfig-to-manage-multi-tenant-saas-configurations/)
- [S27] [LaunchDarkly — Feature Flags 101](https://launchdarkly.com/blog/what-are-feature-flags/)
- [S28] [Chroma Cookbook — Authorization Model with OpenFGA](https://cookbook.chromadb.dev/strategies/multi-tenancy/authorization-model-with-openfga/)
- [S29] [Casbin — Data Permissions / Implicit Permissions](https://www.casbin.org/docs/data-permissions/)
- [S30] [Oso — Build Authorization for Resource Hierarchies](https://docs.osohq.com/guides/more/hierarchies.html)
