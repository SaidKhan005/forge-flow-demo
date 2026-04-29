# Audit Attribution Contract

Updated: 2026-04-28
Owner: Phase 9.0Σ.d (`service_principals`) + Phase 9.0Σ.f (`audit_logs`)
Status: Active authority

## Why This Exists

Two audit tables in Phase 9 carry actor attribution:

- `public.audit_logs` (created in
  `db/migrations/202604280005_phase_9_0sigma_f_audit_logs.sql`,
  Phase 9.0Σ.f / B27) — the SHA-256 hash-chained business-action
  audit trail. One row per audited mutation across the whole
  platform.
- `public.auth_events_audit` (extended in
  `db/migrations/202604280004_phase_9_0sigma_d_service_principals.sql`
  and
  `db/migrations/202604280013_phase_9_audit_actor_kind_live_repair.sql`,
  Phase 9.0Σ.d / B25 + live-closeout repair) — the auth-only audit
  surface that records sign-in, MFA, recovery, and (future)
  service-principal authentication events.

The two tables share the `actor_kind` discriminator but use
**different types** for the non-human principal column:

| Table                | Discriminator | Human column         | Non-human column                       |
|----------------------|---------------|----------------------|----------------------------------------|
| `audit_logs`         | `actor_kind`  | `actor_user_id uuid` | `actor_principal_id text`              |
| `auth_events_audit`  | `actor_kind`  | `actor_user_id uuid` | `actor_service_principal_id uuid`      |

The naming and type divergence is **intentional**, not a drift.
This contract pins the rationale and the safe query posture so
future cross-table reporting does not silently coerce, mis-join,
or under-attribute machine-driven events.

Source references:

- `docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md`
  item 13 (hash-chained audit_logs).
- `docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md`
  item 14 (service_principals + `sp:` JWT subjects).
- `docs/phases/phase_9/phase_9_execution_backlog.md` B25, B27, B34,
  B40.

## The Discriminator: `actor_kind`

Both tables carry `actor_kind text not null check (actor_kind in
('user','service'))`.

- `'user'` — a human Firebase ID-token holder. The matching
  identifier column (`actor_user_id`) MUST be set; the non-human
  column MUST be NULL.
- `'service'` — a non-human principal. The matching non-human
  column MUST be set; `actor_user_id` MUST be NULL.

`audit_logs` enforces this with the
`audit_logs_actor_shape_check` constraint (see
`202604280005_phase_9_0sigma_f_audit_logs.sql`).
`auth_events_audit` does not encode the same paired CHECK because
the live-repair migration kept its scope narrow; the repository
layer (`AuthEventsAuditRepository.insertEvent`) is the contract
enforcer there until a future migration tightens it. Producers
MUST treat the matrix above as binding regardless.

The discriminator value set is closed: introducing a third
`actor_kind` value (e.g. `'workflow'`, `'webhook'` as a top-level
kind) requires a paired migration that updates both CHECK
constraints AND every consumer that branches on `actor_kind`.

## `audit_logs.actor_principal_id text` — Generalized On Purpose

`audit_logs` is the platform-wide business-action trail. It must
accept attributions from principal kinds that do not exist yet:

- `sp:<uuid>` — service principal (the one launch use case for the
  `service` actor_kind in 9.0Σ.d).
- `webhook:<id>` — vendor webhook deliveries that mutate platform
  state without a backing service-principal record (Phase 12 and
  later).
- `cron:<id>` — scheduled jobs that mutate state on the platform's
  own behalf.
- Future principal kinds the platform has not declared yet
  (federated machine identities from a partner integration, signed
  workload identities, etc.).

Storing these as **`text`** with a structured prefix (`<kind>:<id>`)
lets new principal kinds land without an `audit_logs` schema
change. The hash chain (`row_hash`) covers
`actor_principal_id` as raw text bytes, so the canonical encoding
already handles arbitrary-prefix subjects without a verifier
update. The trade-off is that consumers cannot trust the column to
parse to a UUID — they MUST inspect the prefix before joining.

The hash-chain canonical encoding column order is fixed
(`actor_kind` → `actor_user_id::text` → `actor_principal_id` → ...);
see the `audit_logs_chain_insert` trigger function body in
`202604280005_phase_9_0sigma_f_audit_logs.sql`. The post-2026-04-29
encoding uses ASCII `0x1F` (Unit Separator) as the inter-column
delimiter — PostgreSQL `text` cannot contain `0x00`, so an explicit
non-NUL delimiter is what makes the encoding unambiguous. That
column order plus the delimiter choice are part of the chain
contract and cannot be reordered or changed without breaking every
previously-anchored row's `row_hash`.

Index posture:
`(operator_id, actor_principal_id, occurred_at) WHERE
actor_principal_id IS NOT NULL` (partial index) — tenant-leading
and cheap because the bulk of audit rows are user-driven and skip
the partial.

## `auth_events_audit.actor_service_principal_id uuid` — Constrained On Purpose

`auth_events_audit` only records authentication events. The set of
non-human authenticators is, by definition, the set of issued
service principals (each is a row in
`public.service_principals` with a `uuid` primary key). There is no
launch path for a `webhook:` or `cron:` actor to produce an
**auth** event — webhooks and cron jobs do not authenticate
through the proxy auth surface; they execute under a service
principal already.

That bounded surface lets the column be `uuid` with the strongest
typing available:

- The repository can pass the column as a typed UUID parameter
  rather than a stringly-typed cast.
- A future foreign key to `service_principals(id)` can be added
  without a backfill (today it is not declared because 0013 was a
  narrow live-repair).
- The tenant-leading index
  `(operator_id, actor_service_principal_id, occurred_at desc)
  WHERE actor_service_principal_id IS NOT NULL` (in
  `202604280013_phase_9_audit_actor_kind_live_repair.sql`) plans
  faster than a text equivalent and joins to
  `service_principals` with no implicit cast.

If a future principal kind needs to produce an authentication
event (e.g. a federated workload identity that authenticates
through a future SSO surface), the correct extension is a paired
column on `auth_events_audit` (e.g. `actor_workload_identity_id`)
plus a paired update to the `actor_kind` CHECK — not widening
`actor_service_principal_id` to `text`.

## Cross-Table Query Patterns

The two tables answer different questions:

- `audit_logs` — "what did this principal do?" / "is this chain
  intact?" / "show me every action targeting user X".
- `auth_events_audit` — "did this principal sign in?" / "what
  recovery codes were attempted on this account?".

Most operational queries stay in one table. Cross-table reporting
is for compliance review (e.g. "every action a service principal
took on day Y, including the auth event that issued its session"),
and MUST follow one of these patterns:

### Pattern 1 — Prefer the typed column when the question is auth-rooted

If the question starts from auth events ("what business actions
followed this service principal's authentication?"), join the
**typed UUID** column to `service_principals.id`, then to
`audit_logs` via the prefixed text:

```sql
SELECT al.*
FROM public.auth_events_audit ae
JOIN public.service_principals sp
  ON sp.id = ae.actor_service_principal_id
JOIN public.audit_logs al
  ON al.actor_principal_id = 'sp:' || sp.id::text
WHERE ae.operator_id = $1
  AND ae.actor_kind = 'service'
  AND ae.occurred_at >= $2
  AND al.operator_id = ae.operator_id
  AND al.actor_kind = 'service'
  AND al.occurred_at >= ae.occurred_at;
```

The `'sp:' || sp.id::text` prefix construction is the **only**
sanctioned coercion direction. It encodes the prefix on the
`audit_logs` side, where the column is already `text`, instead of
stripping the prefix on the `auth_events_audit` side.

### Pattern 2 — Stripping the prefix on the audit_logs side

When the question starts from `audit_logs` and needs to resolve a
service principal, parse the prefix explicitly. Because
`actor_principal_id` is intentionally free `text`, a `LIKE 'sp:%'`
guard alone still admits malformed payloads (e.g. `sp:not-a-uuid`)
that would throw at the `::uuid` cast. The safe pattern combines a
**prefix guard** with a **UUID-shape regex** before casting:

```sql
-- The 8-4-4-4-12 hex pattern PG accepts for the uuid type.
-- Anchor with ^ / $ so a trailing tail (`sp:<uuid>-extra`) does
-- not coerce. Use POSIX character classes; `~*` is case-insensitive
-- to accept upper- or lower-case hex.
SELECT al.*, sp.name
FROM public.audit_logs al
LEFT JOIN public.service_principals sp
  ON al.actor_kind = 'service'
  AND al.actor_principal_id LIKE 'sp:%'
  AND substring(al.actor_principal_id FROM 4)
        ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  AND sp.id = substring(al.actor_principal_id FROM 4)::uuid
WHERE al.operator_id = $1;
```

The combined guard rules:

- `LIKE 'sp:%'` filters out non-service-principal kinds
  (`webhook:<id>`, `cron:<id>`, future kinds).
- The regex confirms the post-prefix substring matches the canonical
  UUID shape PG would accept. Without it, `sp:not-a-uuid` passes the
  `LIKE` check, reaches the cast, and throws
  `invalid input syntax for type uuid`.
- The `::uuid` cast then runs only on substrings already proven
  cast-safe.

If a row arrives with `sp:` prefix but a non-UUID body (a producer
bug), the LEFT JOIN simply does not match and the row drops out of
the join result — no query-time error. Dispute reconstruction can
still inspect the raw `actor_principal_id` text directly.

A `CASE` branch is an acceptable alternative when the call site
needs to distinguish "matched", "sp-prefixed but malformed", and
"not service-attributed":

```sql
CASE
  WHEN al.actor_kind = 'service'
   AND al.actor_principal_id LIKE 'sp:%'
   AND substring(al.actor_principal_id FROM 4)
         ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    THEN substring(al.actor_principal_id FROM 4)::uuid
  ELSE NULL
END
```

The substring index `FROM 4` is correct for the three-character
`'sp:'` prefix; if a future kind uses a different prefix length the
call site MUST branch on the prefix kind first AND re-derive the
substring offset for that kind.

### Forbidden Patterns

- **Do not** widen the join with a bare cast:
  `sp.id::text = al.actor_principal_id` — drops the `sp:` prefix
  entirely and matches webhook / cron rows that happen to share
  the underlying UUID shape.
- **Do not** strip the prefix without a kind guard:
  `substring(al.actor_principal_id FROM 4)::uuid` — fails on
  non-`sp:` rows.
- **Do not** rely on `LIKE 'sp:%'` alone before `::uuid` —
  malformed payloads (`sp:not-a-uuid`, `sp:`, `sp:<truncated>`)
  still pass the LIKE and throw at the cast. The UUID-shape regex
  guard above is required.
- **Do not** introduce a generated column (`uuid` projection of
  the parsed `sp:` subject) without a paired migration that pins
  the parser into the canonical encoding; the hash chain depends
  on the row's actual stored bytes, not a projection.

## When To Update This Contract

Update when any of the following land:

- A new `actor_kind` value (paired migration on both CHECK
  constraints).
- A new principal-kind prefix on `audit_logs.actor_principal_id`
  (`webhook:`, `cron:`, federated workload identity, ...).
- A new typed actor column on `auth_events_audit` for a non-`sp:`
  authenticator.
- A foreign key from `auth_events_audit.actor_service_principal_id`
  to `service_principals(id)` (currently only enforced at the
  repository layer).
- Any change to the `audit_logs` canonical-encoding column order
  (would break the hash chain; requires a coordinated re-anchor
  plan).

The contract lives next to the other Phase 7-9 architecture
contracts in `docs/contracts/` and is referenced from B25, B27,
B34, and B40 in `docs/phases/phase_9/phase_9_execution_backlog.md`.
