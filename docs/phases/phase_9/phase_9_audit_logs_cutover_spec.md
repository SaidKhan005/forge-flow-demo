# Phase 9 Audit Logs Cutover Spec

Status: Active spec (decision artifact, no code)
Owner: Phase 9 audit cutover slice (writer migration)
Authority refs:
- `docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md` item 13
  (hash-chained `audit_logs` + daily Azure Blob immutable anchor).
- `db/migrations/202604280005_phase_9_0sigma_f_audit_logs.sql` (target schema,
  trigger, RLS, append-only grants).
- `docs/contracts/audit_attribution_contract.md` (live attribution contract;
  this spec extends it for the writer cutover, not replace).

## 1. Decision

**Migrate-and-cutover.** A single audit table — `public.audit_logs` — is the
source of truth for business-action audit rows after the cutover instant.
Every Phase 9 writer that today calls `auth_events_audit` switches its
INSERT path to `audit_logs` at one cutover boundary. After the boundary
no runtime writer touches `auth_events_audit`.

This preserves the SHA-256 hash-chain posture (item 13) end-to-end without
splitting the chain across two tables, avoids dual-table fan-out in every
read surface, and keeps the per-`(operator_id, chain_date)` chain bound to a
single physical writer path.

## 2. Rejected Alternative — Dual-Write

A dual-write path (every writer INSERTs into both `auth_events_audit` and
`audit_logs` for the duration of a parallel-run window) was considered and
rejected.

Justification:

- **Upkeep burden.** Every writer would carry two parameter shapes, two
  failure modes (one table accepts, the other rejects), two tenant-context
  branches, and two grant-shape failure surfaces. Five writers × two paths
  is ten code surfaces to keep behaviorally identical for the lifetime of
  the parallel-run window.
- **Drift risk.** The `audit_logs_set_chain` trigger enforces invariants
  (canonical encoding, `chain_date = (occurred_at at time zone 'UTC')::date`,
  exactly-one-actor CHECK) that `auth_events_audit` does not. Producers that
  satisfied the legacy table but not `audit_logs` would silently land only
  the legacy half, drifting the two stores apart with no chain coverage of
  the drift.
- **No behavior win.** The Hard Promise governing this slice is
  *behavior-preserving* — every legacy callsite must produce an equivalent
  audit row in the new table. Dual-write does not improve that guarantee; it
  weakens it by giving each writer two chances to disagree with itself.
- **Hash-chain hostility.** Dual-write rows on `audit_logs` are real chain
  rows from row 1 forward. A backout of dual-write would have to leave them
  in place or break every subsequent `prev_row_hash` link. The forward-only
  path imposes that constraint exactly once, at cutover, instead of twice
  (cutover + backout).

The migrate-and-cutover path's only weakness is the cutover instant itself —
addressed below by the rollback procedure and freshness-aware read surfaces.

## 3. Affected Writers

Six write boundaries today INSERT into `auth_events_audit`. After cutover
each emits one equivalent `audit_logs` row per legacy row.

| # | File | Insertion site | Today's `event_type` family |
|---|------|----------------|------------------------------|
| W1 | [auth_events_audit_repository.dart:106](lib/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart:106) | `insertEvent` (tenant scope) | every event_type — this is the shared writer |
| W1 | [auth_events_audit_repository.dart:172](lib/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart:172) | `insertSystemEvent` (system scope, BYPASSRLS) | F&F-global lifecycle / onboarding events |
| W2 | [mfa_operations_gateway.dart:556](lib/services/mfa/mfa_operations_gateway.dart:556) | `_auditRepository.insertEvent` — `mfa_factor_revocation_cancelled` | `mfa_*` |
| W2 | [mfa_operations_gateway.dart:624](lib/services/mfa/mfa_operations_gateway.dart:624) | `_auditRepository.insertEvent` — `mfa_factor_revocation_initiated` | `mfa_*` |
| W2 | [mfa_operations_gateway.dart:729](lib/services/mfa/mfa_operations_gateway.dart:729) | `_audit` helper — TOTP enroll outcomes | `auth.mfa_totp_enroll_*` |
| W3 | [repository_password_change_gateway.dart:131](lib/services/auth/repository_password_change_gateway.dart:131) | `_audit` helper | `password_change_*`, `password_*`, `hibp_unavailable` |
| W4 | [repository_auth_operations_gateway.dart:1359](lib/services/auth/repository_auth_operations_gateway.dart:1359) | `_audit` helper | role grants/revokes, session ops, admin lifecycle events |
| W5 | [invited_user_activation_repository.dart:99](lib/infrastructure/persistence/postgres/repositories/invited_user_activation_repository.dart:99) | inline `insert into auth_events_audit ...` | `auth.invite_accepted` |
| W6 | [advisor_proxy.dart:1953](tool/advisor_proxy/advisor_proxy.dart:1953) | `PostgresServicePrincipalJwtIssuanceGateway._insertAuditRow` — inline `insert into public.auth_events_audit ...` (B41) | `admin.service_principal.issue_token` |

W1's two methods (`insertEvent`, `insertSystemEvent`) are the shared
proxy-writer surface that W2 / W3 / W4 call into. W5 keeps its own raw
INSERT because it must run inside the same transaction as the
`users.invited_status` UPDATE for atomicity. **W6 likewise keeps its own
raw INSERT** because it must run inside the same transaction as the
service-principal token issuance plus the `proxy_requests` idempotency
row, and is also the only writer today that legitimately produces
`actor_kind = 'service'` rows. The cutover slice rewrites four physical
SQL sites — W1's two INSERT statements, W5's inline INSERT, and W6's
inline INSERT — against `audit_logs`, plus the call-site parameter
shapes in W2 / W3 / W4 to satisfy the new required-fields posture (see
§5).

**Read-side note (not a writer, but adjacent):** W6 also issues a
`SELECT count(*) ... FROM public.auth_events_audit` rate-limit probe at
[advisor_proxy.dart:1922](tool/advisor_proxy/advisor_proxy.dart:1922).
After cutover this read must be repointed at `audit_logs` (filter by
`action = 'admin.service_principal.issue_token'` and the `'sp:' ||
<uuid>` form of `actor_principal_id`) **or** continue reading from the
read-only `auth_events_audit` and accept that the rate-limit window only
covers pre-cutover history until the read swap lands. B.2 owns the read
swap because the rate limiter would otherwise undercount the moment
cutover flips.

## 4. Field Mapping

Legacy `auth_events_audit` columns map to `audit_logs` as follows. Every
row produced after cutover uses this mapping; any column not listed has
no equivalent on the new table and is dropped from the row.

| Legacy `auth_events_audit` | New `audit_logs` | Mapping rule |
|----------------------------|------------------|--------------|
| `event_id uuid` (PK) | — | Replaced by `bigserial id`. Legacy `event_id` is **not** carried into `audit_logs.id` (type mismatch + chain semantics). Cross-table reconciliation joins on `(operator_id, occurred_at, action, target_id)`. |
| `operator_id uuid NULL` | `operator_id uuid NOT NULL` | Direct copy when present. **Tightened nullability:** legacy `auth_events_audit` accepts NULL for F&F-global / system-onboarding events; `audit_logs.operator_id` is NOT NULL (PK component). System-scope events that previously left this NULL must resolve to either (a) the F&F-platform sentinel `operator_id` reserved for global system events, or (b) the actual `target_operator_id` if the event affects a specific operator. The shared `insertSystemEvent` writer is the only producer of this case; its rewrite picks (b) when the system event names a target, otherwise (a). |
| `location_id uuid NULL` | `location_id uuid NULL` | Direct copy. |
| `actor_kind text NOT NULL DEFAULT 'user'` | `actor_kind text NOT NULL` | Direct copy. Closed enum `('user', 'service')` on both sides. |
| `actor_user_id uuid NULL` | `actor_user_id uuid NULL` | Direct copy. The `audit_logs_actor_shape_check` constraint then requires NULL when `actor_kind = 'service'` — already true today by repository-layer contract. |
| `actor_service_principal_id uuid NULL` | `actor_principal_id text NULL` | **Type + name change** per `audit_attribution_contract.md`. Mapping rule: `actor_principal_id := 'sp:' || actor_service_principal_id::text` when `actor_kind = 'service'`. The `'sp:'` prefix is required so future principal kinds (`webhook:`, `cron:`) can land without an `audit_logs` schema change. The hash-chain canonical encoding is sensitive to the prefix; producers MUST emit it exactly as `'sp:<uuid>'`, never bare `<uuid>`. |
| `target_user_id uuid NULL` | `target_kind text NULL`, `target_id text NULL` | **Lift to a typed pair.** When the legacy row carries a `target_user_id`, the new row sets `target_kind = 'user'` and `target_id = target_user_id::text`. Rows with no `target_user_id` set both new columns to NULL. Future writers that target operators / roles / integrations set `target_kind` to `'operator'`, `'role'`, `'integration'`, etc., and `target_id` to the relevant UUID-as-text or stable identifier. |
| `event_type text NOT NULL` | `action text NOT NULL` | Direct copy of the string value, column rename only. The existing event-type vocabulary (`auth.invite_accepted`, `mfa_factor_revocation_initiated`, `password_change_succeeded`, …) carries forward unchanged so cross-cutover reads can union the two stores by string equality on `event_type` / `action`. |
| `event_payload jsonb NOT NULL DEFAULT '{}'` | `payload jsonb NOT NULL DEFAULT '{}'` | Direct copy of the object body. `audit_logs.payload` is constrained to `jsonb_typeof = 'object'` and ≤ 256 KB; today's writers already pass objects under that ceiling. The flatten rule below adds the four legacy top-level fields into the payload object. |
| `ip inet NULL` | `payload.ip` (text) | **Flattened into payload.** `audit_logs` has no top-level network column. Encode as the canonical text form (`host(ip)`); rendering is identical to today's read projection at [auth_events_audit_repository.dart:276](lib/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart:276). |
| `user_agent text NULL` | `payload.user_agent` | Flattened into payload. |
| `geo_country char(2) NULL` | `payload.geo_country` | Flattened into payload. |
| `request_id uuid NULL` | `payload.request_id` (text) | Flattened into payload as the canonical UUID text form. |
| `occurred_at timestamptz NOT NULL DEFAULT now()` | `occurred_at timestamptz NOT NULL DEFAULT now()` | Direct copy. The trigger-derived `chain_date` follows from this column. |
| `schema_version int NOT NULL DEFAULT 1` | — | Dropped. The `audit_logs` chain encoding is itself the schema invariant; a producer-controlled version field would let a malicious producer change the canonical encoding without changing the `row_hash`. If schema-version-style metadata is needed in the future, it lands in `payload._schema_version`. |
| — | `chain_date date NOT NULL` | Trigger-derived: `(occurred_at at time zone 'UTC')::date`. Producers MUST set the column matching this rule (the `audit_logs_chain_date_matches_occurred_at` CHECK rejects mismatches). |
| — | `prev_row_hash bytea NULL`, `row_hash bytea NOT NULL` | Trigger-set by `audit_logs_set_chain`. Producers do not supply these columns; any producer-supplied value is overwritten. |

### `actor_kind` resolution

Both `auth_events_audit.actor_kind` and `audit_logs.actor_kind` are
closed enums `('user', 'service')` (see
`202604280004_phase_9_0sigma_d_service_principals.sql` and
`202604280005_phase_9_0sigma_f_audit_logs.sql`). Every cutover writer
sets `actor_kind` explicitly per row, never by relying on a default,
and resolves to one of exactly two values:

- **Human actor.** `actor_kind = 'user'` AND `actor_user_id` is set
  AND `actor_principal_id` is NULL. This matches the legacy default and
  is the dominant case for W2 / W3 / W4 / W5.
- **Service actor.** `actor_kind = 'service'` AND `actor_principal_id`
  is set as `'sp:' || <uuid>::text` (where `<uuid>` is the
  `service_principals.id` UUID, **not** the row's `name`) AND
  `actor_user_id` is NULL. This matches the safe join patterns in
  `audit_attribution_contract.md` §"Cross-Table Query Patterns" which
  parse the post-`'sp:'` substring as a UUID. Today only W6 and the
  shared writer's `actorKind: 'service'` path produce these rows.

#### Existing `actorKind: 'system'` callsites — must normalize to `'service'`

Three live callsites today pass `actorKind: 'system'` to
`AuthEventsAuditRepository.insertSystemEvent`:

- [password_reset_request_gateway.dart:74](lib/services/auth/password_reset_request_gateway.dart:74)
  — `auth.password_reset_requested`
- [password_reset_confirm_gateway.dart:163](lib/services/auth/password_reset_confirm_gateway.dart:163)
  — password-reset confirm outcome
- [mfa_removal_worker.dart:96](lib/services/mfa/mfa_removal_worker.dart:96)
  — scheduled MFA factor removal

The `'system'` value is **not** in the closed enum on either
`auth_events_audit` (post-`202604280013` live-repair) or
`audit_logs`. These callsites already violate the legacy CHECK; the
cutover slice cannot ignore them because they will fail equally hard
on the new table. B.2 normalizes all three to `actor_kind = 'service'`
attributing to the F&F system sentinel principal (below). No
`'system'` value lands in either table after cutover. The `actorKind`
parameter on `insertSystemEvent` (and on the post-cutover
`audit_logs` writer) is restricted to `'user' | 'service'`; passing any
other value is a compile-time / runtime error, not a database-layer
reject.

#### F&F system sentinel principal

For events that have no human and no operator-issued service
principal (the three callsites above, plus future system-scope events
that hit `insertSystemEvent` without an actor), F&F provisions a
two-row sentinel pair: a platform-sentinel `operators` row and a
sentinel `service_principals` row that points at it.

**The FK chain forces the operator row to exist first.**
`service_principals.operator_id` has a `NOT NULL` FK to
`operators(operator_id) ON DELETE CASCADE` (see
`db/migrations/202604280004_phase_9_0sigma_d_service_principals.sql`),
and repo search on 2026-05-01 found no platform-sentinel `operators`
row, no `kPlatform*` / `kFf*` operator-id constant, and no migration
that seeds one. B.2 must seed both rows or the sentinel
`service_principals` INSERT fails on the FK.

B.2's migration set lands the sentinel pair as follows:

1. **Schema marker on `operators`** — `ALTER TABLE public.operators
   ADD COLUMN is_platform_sentinel boolean NOT NULL DEFAULT false`.
   The default keeps every existing operator row unaffected; only
   the sentinel row sets it to `true`. The column exists so that
   operator-facing admin lists (F&F operator admin, pricing-tier
   admin, and any future operator-list consumer) can default-exclude
   the sentinel without each consumer having to know its UUID.
   Audit-anchor scans deliberately do **not** use this default
   exclusion — see step 3.
2. **Sentinel operator row** — `INSERT INTO public.operators` with a
   fixed UUID `<SENTINEL_OPERATOR_UUID>`, `is_platform_sentinel =
   true`, and a clearly-marked `business_name` (e.g. `'F&F Platform
   (system sentinel — do not delete)'`). The UUID is pinned in the
   migration body. Any other columns required by `operators` get
   F&F-internal-only sentinel values.
3. **Repository-layer exclusion (admin/pricing only)** —
   `OperatorsRepository.listOperators`
   ([operators_repository.dart:31](lib/infrastructure/persistence/postgres/repositories/operators_repository.dart:31))
   and `OperatorsRepository.findById`
   ([operators_repository.dart:49](lib/infrastructure/persistence/postgres/repositories/operators_repository.dart:49))
   add `where is_platform_sentinel = false` to their SQL by default.
   Both downstream admin consumers
   ([operator_location_admin_gateway.dart:85](lib/admin/services/operator_location_admin_gateway.dart:85),
   [pricing_tier_admin_gateway.dart:84](lib/admin/services/pricing_tier_admin_gateway.dart:84) +
   [pricing_tier_admin_gateway.dart:193](lib/admin/services/pricing_tier_admin_gateway.dart:193))
   delegate to these repository methods, so a single repository-layer
   filter covers the F&F operator admin and pricing-tier admin
   surfaces in one edit.

   **Audit anchoring MUST include the sentinel.** System-scope audit
   rows cluster under `<SENTINEL_OPERATOR_UUID>` (see the §4
   `operator_id` mapping), so the sentinel chain is a real
   `(operator_id, chain_date)` chain that needs the same daily Azure
   Blob immutable anchor as every customer chain. Excluding the
   sentinel from anchor scans would leave those chains permanently
   un-anchored and forfeit the SOC 2 forensic guarantee for every
   system-scope event (password resets, MFA worker actions, service-
   principal token issuances, future system-scope events).
   `tool/audit_anchor/` therefore drives its operator iteration off a
   separate explicit accessor (`listOperatorsIncludingSentinel()` or
   equivalent — name pinned in B.2) that does **not** apply the
   `is_platform_sentinel = false` filter. The same applies to the
   chain-verifier and any cross-tenant F&F admin/debug paths that
   need to inspect system-scope chains. The default
   `listOperators` / `findById` API never returns the sentinel — that
   is the operator-facing default; anchor and verifier paths
   explicitly opt in.
4. **Sentinel service principal row** — `INSERT INTO
   public.service_principals` with:
   - `id = <SENTINEL_PRINCIPAL_UUID>` (separate fixed UUID)
   - `operator_id = <SENTINEL_OPERATOR_UUID>` (the row from step 2)
   - `name = 'ff-platform-system'` (human-readable; not stored in
     `actor_principal_id`)
   - `scopes` = the minimal scope set required for system-scope audit
     attribution (the migration body specifies the exact JSON; this
     spec does not pin scope policy).
5. **Dart constants** — `kSystemSentinelOperatorId` and
   `kSystemSentinelPrincipalId` exposed from a single
   `lib/auth/system_sentinels.dart` (or equivalent under `lib/auth/`,
   which is the frozen permission-key catalog directory) so writer
   call sites cannot drift from the seeded UUIDs.
6. **Tests** — the B.2 migration test asserts:
   - Both sentinel rows exist after migration.
   - The constants in step 5 match the seeded UUIDs byte-for-byte.
   - `OperatorsRepository.listOperators` returns zero rows when the
     sentinel row is the only `operators` row (guards against
     accidental removal of the `is_platform_sentinel` filter).
   - `OperatorsRepository.findById(kSystemSentinelOperatorId)`
     returns `null` (the default API never reveals the sentinel).

System-scope audit rows then attribute as:

- `actor_kind = 'service'`
- `actor_principal_id = 'sp:' || <SENTINEL_PRINCIPAL_UUID>::text`
- `actor_user_id = NULL`

For the §4 `operator_id` mapping, system-scope audit rows that have
no business operator target use `<SENTINEL_OPERATOR_UUID>` — this is
the same row referenced by the sentinel principal's `operator_id` FK,
so RLS-bypassing reads of system-scope audit history naturally cluster
under the sentinel operator without polluting any real operator's
chain.

This satisfies (a) the closed `actor_kind` enum on both tables, (b)
the `audit_logs_actor_shape_check` CHECK (exactly one of
`actor_user_id` / `actor_principal_id` is set), (c) the
`audit_attribution_contract.md` §"Pattern 2" prefix-then-UUID-shape
join — `substring(actor_principal_id from 4)` is a valid UUID that
joins to `service_principals.id` — and (d) the `service_principals →
operators` FK that previously had no satisfying row in this codebase.
Storing `'sp:ff-platform-system'` literally as `actor_principal_id`
would fail the UUID-shape regex in the safe join pattern and cause
every compliance query that resolves audit rows to service principals
to silently miss the sentinel-attributed rows.

#### Excluded shapes

The closed enum value set is binding. Adding `'workflow'` or
`'webhook'` as a new top-level `actor_kind` requires the paired CHECK
update flagged in `audit_attribution_contract.md` §"Discriminator"
and is **out of this spec's scope** — those producers attribute
through `'service'` + a kind-specific `actor_principal_id` prefix
(`'webhook:'`, `'cron:'`) per the contract.

## 5. Behavior Preservation

Cutover is behavior-preserving by construction. For every legacy callsite
listed in §3, the post-cutover code path produces one `audit_logs` row
that:

1. **Same actor.** `actor_kind`, `actor_user_id`, and `actor_principal_id`
   resolve from the same call-site values via §4's mapping. No event
   that legacy attributed to a human re-attributes to a service after
   cutover, and vice versa.
2. **Same target.** `(target_kind, target_id)` derives from the same
   `target_user_id` parameter when present; rows that legacy left
   targetless stay targetless.
3. **Same action vocabulary.** `audit_logs.action` carries the
   identical string the legacy row's `event_type` carried — cross-table
   reads union the two stores on equal action strings without translation
   tables.
4. **Same semantics.** `payload` is the legacy `event_payload` object
   plus the four flattened legacy top-level fields (`ip`, `user_agent`,
   `geo_country`, `request_id`) under their listed keys. No payload
   value is rewritten, dropped, or re-typed.
5. **Same control flow.** No gateway changes its rejection behavior, its
   transaction boundary, its error-handling contract, or the order in
   which it audits relative to the business mutation. The cutover slice
   is *strictly* a write-target swap; it does not move audit calls
   relative to their business operations, does not collapse two events
   into one, and does not split one event into two.
6. **Same failure mode.** Where a legacy row would have failed (RLS
   reject, grant violation, malformed payload), the cutover row fails
   in an equivalent way: `audit_logs` carries the same RLS posture and
   tighter (but compatible) producer-side CHECKs. The
   `audit_logs_actor_shape_check` failure surface is the only new
   rejection class, and only system-scope writers can hit it (and only
   when they fail to resolve a principal — see §4 sentinel rule).

Specifically excluded from this slice: any change to **what** is logged.
Adding new event types, expanding payloads, retiring deprecated event
types, or changing the order in which audit happens vs. the business
mutation are **not** part of cutover. They land in their own follow-up
slices on top of `audit_logs`.

## 6. Cutover Timestamp Policy + Rollback

### Cutover boundary

The cutover is gated by a single global-scope row in the existing
`public.feature_flags` table (created in
`db/migrations/202604250005_advisor_cloud_foundation.sql`):

- `flag_name = 'audit_logs_cutover_enabled'`
- `operator_id = NULL`, `location_id = NULL` (global scope; covered by
  `feature_flags_global_scope_idx`)
- `enabled boolean` — `false` before cutover, `true` after
- `updated_at timestamptz` — the canonical cutover instant `T_cutover`
  is the value of `updated_at` at the moment `enabled` is flipped to
  `true`. There is no separate timestamp column to maintain.

The `feature_flags` table is the existing schema contract; this spec
adds one row, not a new table. **There is no runtime
`feature_flags` reader in `tool/advisor_proxy/` today** — repo search
on 2026-05-01 found zero references in `lib/` and `tool/advisor_proxy/`
(only `tool/index_leading_column_lint.dart` references the table, and
only as a CI-lint exemption). B.2 therefore owns three deliverables on
the flag side, not just the row seed:

1. **Migration** — INSERT one row into `public.feature_flags` with
   `flag_name = 'audit_logs_cutover_enabled'`, `operator_id = NULL`,
   `location_id = NULL`, `enabled = false`. The row's
   `feature_flags_global_scope_idx` partial unique index guarantees
   exactly one global-scope row with that name.
2. **Proxy snapshot seam** — a new reader in `tool/advisor_proxy/`
   that issues one `SELECT enabled, updated_at FROM
   public.feature_flags WHERE flag_name = 'audit_logs_cutover_enabled'
   AND operator_id IS NULL AND location_id IS NULL` at proxy startup
   (post-DB-pool-init, pre-server-bind), caches the boolean in a
   singleton, and exposes it to every audit-write call site. The
   reader is the seam that controls dispatch; without it the row flip
   has no runtime effect. The seam is the **only** consumer at this
   slice; later runtime config can reuse the same shape.
3. **Deploy runbook entry** — the `UPDATE` that flips `enabled` to
   `true` plus the proxy redeploy step that picks up the new
   snapshot. Lives in `runbooks/audit_chain_verify_runbook.md`
   alongside the existing audit-chain operational steps.

For all writers in §3 the dispatch is **deploy-deterministic, not
per-row**: the proxy snapshot reads the flag once at startup and binds
it to a singleton; every subsequent INSERT from that proxy instance
respects the snapshot. This avoids a writer that flips mid-transaction
and produces a half-and-half audit trail for one logical operation.

A clock-skew guard inside the proxy refuses to start if its host clock
and the database `now()` disagree by > 5s; the cutover boundary must
not float across hosts.

### Forward-only cutover

After the flag flips and the proxy redeploys, the writers are committed
to `audit_logs` for the lifetime of the deploy. The `auth_events_audit`
table receives no further runtime INSERTs from the writers listed in §3.

### Rollback procedure

Rollback is reserved for a critical bug discovered post-cutover that
makes `audit_logs` writes incorrect or unreliable. The procedure:

1. **Flag flip via runbook.** A DBA `UPDATE`s
   `public.feature_flags SET enabled = false, updated_at = now() WHERE
   flag_name = 'audit_logs_cutover_enabled' AND operator_id IS NULL
   AND location_id IS NULL`, then redeploys the proxy. The new
   snapshot reads `enabled = false`; the writers route to
   `auth_events_audit` again. This is the only sanctioned rollback path.
2. **Audit the rollback.** The same DBA writes one explicit `audit_logs`
   row attributing the rollback to the F&F super-admin actor with
   `action = 'audit_logs_cutover_rollback'` and a payload describing
   the trigger. This row is the last `audit_logs` row in its chain
   for the affected operator/day until cutover is re-attempted.
3. **Read surfaces during rollback window.** Any read surface that needs
   to display audit history during the rollback window (Phase 9.UX.6
   self-service Audit Log, F&F admin audit review) reads both
   `audit_logs` and `auth_events_audit` and unions them on (operator_id,
   action, occurred_at). The pattern follows the cross-table rules in
   `audit_attribution_contract.md` §"Cross-Table Query Patterns".
4. **No row-level rollback.** Rows already written to `audit_logs`
   stay there. Deleting them or rewriting their hashes breaks every
   downstream `prev_row_hash` link in the chain and invalidates the
   already-anchored Azure Blob evidence. The rollback must accept that
   the cutover-window rows live in the new table and the rollback-window
   rows live back in the old one.

Re-attempting cutover after rollback follows the same procedure in
reverse: fix the bug, flip
`feature_flags.audit_logs_cutover_enabled` back to `true`, redeploy.
The hash chain picks up where it left off (the new rows continue the
existing per-operator/day chain).

## 7. Backfill Policy — Forward-Only

**No historical backfill of `auth_events_audit` rows into `audit_logs`.**

Justification — chain integrity:

- The `audit_logs_set_chain` trigger computes
  `row_hash = SHA256(prev_row_hash || canonical_payload)`. Backfilled
  rows would either:
  - Land at the *current* tail of their `(operator_id, chain_date)`
    chain, which means a 2026-01-15 legacy row would be hashed against
    the current tail of the 2026-01-15 chain — but that chain may not
    exist if no audit_logs row was ever written for that day, or worse,
    the existing audit_logs rows for that day landed in chronological
    `id` order that pre-dates the backfilled `occurred_at`, breaking
    the implicit ordering guarantee.
  - Or be inserted ahead of existing rows by manipulating the
    `bigserial id`, which requires `UPDATE`/`DELETE` privileges on the
    table that the locked grant shape forbids and that the
    `audit_chain_anchors` ledger would flag at next anchor verification
    as a chain divergence.
- The Azure Blob immutable anchor for any day already verified before
  backfill would no longer match a chain that contains backfilled rows.
  Re-anchoring to "match" the backfilled chain would defeat the
  forensic guarantee the anchor exists to provide.

`auth_events_audit` therefore remains the authoritative store for
pre-cutover audit history. Read surfaces that span the cutover instant
union the two tables (see §6 step 3). Compliance / forensic queries
against pre-cutover history continue to run against `auth_events_audit`.

## 8. Test Gates

- **B.3 e2e suite — must pass at cutover slice close.** The end-to-end
  audit suite at
  [phase_9_0sigma_f_audit_chain_e2e_test.dart](test/phase_9_0sigma_f_audit_chain_e2e_test.dart)
  exercises the full hash-chain posture: 100 rows × 3 operators × 2
  chain_dates, with verifier reconciliation against
  `audit_chain_anchors`. Today the suite **fails by design** because
  the gateways listed in §3 still write to `auth_events_audit` instead
  of `audit_logs`; the suite asserts that audit-relevant calls produce
  `audit_logs` rows. Closing the cutover writer slice (B.2) is
  exactly what makes this suite pass.
- **No new tests in this spec.** The cutover slice itself adds no
  contract behavior beyond what B.3 already asserts. New tests for new
  behavior (e.g., target_kind expansion to `'role'` / `'integration'`)
  land in their respective follow-up slices.
- **No re-running of `dart analyze` for this spec.** This is a
  decision artifact only; no source code changed.

## 9. Deprecation Timeline for `auth_events_audit`

The table does not drop on cutover day. Deprecation runs through three
checkpoints:

1. **Cutover day (`T_cutover`, this spec's slice + B.2).** Writers
   stop INSERTing. The table goes runtime-read-only by behavior; the
   grant shape stays as it is (INSERT + SELECT) so the live-repair
   migration that landed the actor_kind column does not need to be
   reverted. Rollback (§6) relies on the INSERT grant remaining valid.
2. **Cutover stabilization slice (post-rollback window expires).** Once
   F&F has accepted that no rollback will happen for the cutover, a
   follow-up migration narrows the runtime grant to SELECT only:
   `REVOKE INSERT ON public.auth_events_audit FROM service_role,
   forge_admin`. UPDATE / DELETE are already revoked. The table is
   now physically append-only frozen — pre-cutover history stays
   intact, no new rows land. This slice is **not part of B.2**; it
   lands as a separate cutover-stabilization slice once the rollback
   window has closed (calendar-driven, ≥ 30 days post-cutover).
3. **Compliance retention exit slice (≥ 7 years post-cutover, per item
   20 / Q9).** Once the 7-year retention floor passes for the youngest
   row in `auth_events_audit`, a final migration `DROP TABLE
   public.auth_events_audit CASCADE` after evidence export to the F&F
   immutable evidence archive. Until that slice runs, the table is
   queryable historical evidence.

This timeline is intentionally conservative: the chain-integrity
argument of §7 means the legacy table is the only source of pre-cutover
audit truth, and pre-launch SOC 2 / forensic reviews will reach back into
that truth. Dropping the table earlier than the retention floor permits
would forfeit that evidence.

## 10. Cross-References

- `docs/contracts/audit_attribution_contract.md` — extended (not
  replaced) by §4's cutover-time mapping rules. Producers cite the
  contract for query patterns; this spec governs the write side at the
  cutover boundary.
- `db/migrations/202604280005_phase_9_0sigma_f_audit_logs.sql` — target
  schema referenced throughout §4 / §5.
- `runbooks/audit_chain_verify_runbook.md` — cutover and rollback
  steps land here as runbook entries when B.2 ships.
- `docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md`
  item 13 — the decision this spec implements.
