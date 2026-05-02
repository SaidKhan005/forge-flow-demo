# Hardening — Feature Flag Idempotency Contract

> **Status (2026-05-02):** Closed (in-memory layer shipped; Postgres-durable
> backstop deferred — see "Implementation Decision (2026-05-02)" section
> below). Shipped commit `5b51fd0` (PR #45). Contract is retained as
> historical authority and as the future-promotion checklist for when
> `admin_idempotency_cache` next gets touched or the proxy moves off
> single-instance posture.


Updated: 2026-05-02
Owner: HARD-D (idempotency sprint)
Status: Active authority

## Why This Exists

`POST /v1/admin/feature-flags/toggle` accepts an `Idempotency-Key` header
and logs it in the audit payload but never deduplicates. Two retries with
the same key produce two audit rows and two `updated_at` mutations. The
graph-commit path at `proxy_bootstrap.dart:1600–1635` already implements
the correct pattern (in-memory result Future cache keyed by idempotency
key plus `proxy_requests` UNIQUE constraint). This contract aligns the
feature-flag toggle to that pattern.

Handoff between:

- `tool/advisor_proxy/proxy_bootstrap.dart:2371–2399` — `toggleFlag` entry.
- `tool/advisor_proxy/feature_flags_repository.dart` — DB layer that
  writes audit and flag state.
- `db/migrations/` — uses existing `proxy_requests` table from
  `202604250005_advisor_cloud_foundation.sql`.

Disagreement rule: this contract wins. RFC 9110 (semantics of
`Idempotency-Key`) is the underlying standard.

## In Scope

| Item | In | Out |
|------|-----|-----|
| Feature flag toggle idempotency dedup | yes | other admin POSTs (ship-by-ship, not in this contract) |
| Same-key + different-payload conflict detection | yes | structural retry (HTTP-level retry — client owns) |
| Audit row deduplication | yes | audit-row immutability (already enforced) |

Out of scope: applying this pattern to corpus/integration/pricing admin
routes — those are handled in their own follow-up if Codex finds gaps.

## Required Behavior

`toggleFlag(flagId, enabled, actorUserId, idempotencyKey, adminReason?)` must:

1. **Reserve.** Begin a tenant-bound transaction. Insert into
   `public.proxy_requests` with `(idempotency_key, request_type='admin.feature_flag_toggle', status='in_flight', payload_hash=sha256(canonical_payload))`.
   - `payload_hash` is SHA-256 of `{flag_id, enabled, admin_reason, actor_user_id}`
     serialized in canonical (sorted-key) JSON.
   - Use `ON CONFLICT (idempotency_key) DO NOTHING`. If conflict:
     - Re-read the existing row.
     - If existing `request_type` mismatches → return HTTP **409** with
       `{"error":"idempotency_request_in_flight"}` (existing semantic).
     - If existing `payload_hash` matches → return the cached
       `result_payload` from the prior row, with original status code.
     - If `payload_hash` differs → return HTTP **422** with
       `{"error":"idempotency_payload_mismatch"}`. **Do not** mutate.
2. **Execute.** If reservation succeeded, perform the flag toggle and
   audit emission inside the same transaction.
3. **Complete.** Update the `proxy_requests` row with `status='completed'`,
   `result_payload=<response body>`, `completed_at=now()`. Commit.
4. **In-process cache.** Memoize result Future by idempotency key for the
   process lifetime to short-circuit duplicate retries that arrive
   before Postgres records the conflict (mirrors graph-commit pattern).

## Request / Response Envelope

Request:

```json
POST /v1/admin/feature-flags/toggle
Idempotency-Key: <opaque-string, max 200 chars>
Content-Type: application/json

{ "flag_id": "...", "enabled": true, "reason": "..." }
```

Successful response (first call): HTTP 200 with toggle result. Subsequent
identical retries: HTTP 200 with the same result body.

Error responses:

| Status | Code | Meaning |
|--------|------|---------|
| 400 | `idempotency_key_missing` | `Idempotency-Key` header absent |
| 400 | `idempotency_key_too_long` | `>200` chars |
| 409 | `idempotency_request_in_flight` | Same key reused for a different `request_type` |
| 422 | `idempotency_payload_mismatch` | Same key + same route, different payload |

## Audit-Row Coverage

A retry that hits the cached result MUST NOT emit a second
`admin.feature_flag_toggled` audit row. The first call emits exactly one
row; retries return cached `result_payload` without re-emission. Test
coverage must assert `audit_logs` row count == 1 after N retries with the
same key.

## In-Memory Cache Lifetime

- Keyed by `(request_type, idempotency_key)`.
- Bounded LRU with at least 1,024 entries; evict on size.
- Cleared on process restart; long-tail safety relies on Postgres
  `proxy_requests` UNIQUE constraint.
- Not shared across instances (matches single-instance posture; document
  in code comment).

## Out of Scope

- Cross-instance idempotency cache (Phase 12 multi-region).
- TTL-based dedup window — relies on `proxy_requests` retention only.
- Idempotency for non-admin advisor calls — already handled per route.

## Test Surface

- Unit tests for `toggleFlag` covering:
  - First call → success with audit row.
  - Same key, same payload → cached response, exactly one audit row.
  - Same key, different payload → 422.
  - Same key, different route → 409.
  - Concurrent same-key calls → exactly one audit row, one DB mutation
    (verify via parallel POST harness).
  - In-memory cache evicts at LRU limit; eviction does not corrupt DB.
- Integration test using `proxy_requests` UNIQUE constraint, asserting
  the conflict path returns the cached result (not a fresh execution).
- `dart analyze --fatal-infos`.

## Codex Acceptance

- [ ] `toggleFlag` reserves into `proxy_requests` before mutating.
- [ ] In-memory cache memoizes result Future by `(request_type, key)`.
- [ ] Same-key + same-payload retries return single audit row (test asserts).
- [ ] Same-key + different-payload returns 422 with no mutation.
- [ ] Same-key + different-request-type returns 409.
- [ ] All listed tests pass; `dart analyze --fatal-infos` clean.

## Implementation Decision (2026-05-02)

HARD-D shipped the in-memory layer of this contract and **deferred the
Postgres-durable backstop**. The "Required Behavior" §1 (`INSERT INTO
proxy_requests …`) and §3 (`UPDATE … status='completed'`) are not in the
shipped code; the cache lives only in `RepositoryFeatureFlagsAdminProxyGateway`'s
`FeatureFlagToggleIdempotencyCache` field for the proxy process lifetime.

### Why we deferred the Postgres half

Three structural mismatches between this contract and the existing
`proxy_requests` table:

1. **Schema doesn't carry the columns the contract names.**
   `proxy_requests` (created in
   `db/migrations/202604250005_advisor_cloud_foundation.sql:196` and
   reshaped by `db/migrations/202604250007_advisor_rls_index_hardening.sql:32`)
   has `request_id`, `idempotency_key`, `request_type`, `operator_id`,
   `location_id`, `usage_class`, `response_payload`, `created_at`,
   `updated_at`. None of `status`, `payload_hash`, `result_payload`,
   `completed_at` exist. A new migration would have to add them.

2. **The UNIQUE is `(operator_id, location_id, idempotency_key)`, not
   `(idempotency_key)`.** The 11a.11c.6 RLS-leading-column hardening
   pinned the tenant pair as the key prefix so policy evaluation stays
   index-friendly. `ON CONFLICT (idempotency_key) DO NOTHING` as written
   in §1 would not compile against the live schema.

3. **The toggle route is cross-tenant; `proxy_requests` is per-tenant.**
   `operator_id` and `location_id` are NOT NULL with FK to `locations`.
   The toggle handler runs as a `super_admin` actor with no tenant
   scope (`tool/advisor_proxy/advisor_proxy.dart:8294-8318`), so there
   is nothing to put in those required columns. The 11A.3a comment at
   `db/migrations/202605010000_phase_11A_3a_corpus_versions_ledger.sql:208`
   already records this fit problem and created `admin_idempotency_cache`
   for cross-tenant admin dedup. That table also lacks the
   `payload_hash` / `request_type` / `status` columns this contract
   needs.

### What we shipped instead

Option B from the HARD-D conversation: in-memory `LinkedHashMap`-backed
LRU keyed on `idempotencyKey`, with each entry carrying `requestType`
+ `payloadHash` so the 409 / 422 envelopes still fire. Reservation
runs in the synchronous prefix of `runOrReplay` (mirrors the
graph-commit pattern at `proxy_bootstrap.dart:1600–1635`), so
concurrent same-key retries collapse to one compute. The 1,024-entry
LRU bound and the cleared-on-restart posture from the "In-Memory
Cache Lifetime" section above are honored. Header validation
(`idempotency_key_missing`, `idempotency_key_too_long`) lives in the
route handler.

Two follow-up audit findings from the same day were addressed in the
same slice and are reflected in the implementation that ships:

1. **Atomic toggle + audit.** Required Behavior §2 ("perform the
   flag toggle and audit emission inside the same transaction") is
   honored even though the Postgres-durable §1/§3 are deferred.
   `FeatureFlagsRepository.toggleFlag` accepts an `onCommit(exec, row)`
   callback that runs inside the same `withSystem` transaction the
   UPDATE opens. The gateway threads `AuthEventsAuditRepository`'s
   new `insertSystemEventOn(exec, …)` through that callback, so the
   `feature_flags` UPDATE, the `auth_events_audit` INSERT, and the
   hash-chained `audit_logs` fan-out commit (or roll back) together.
   An audit failure can no longer leave a flag mutation unaudited.

2. **In-flight cache entries are pinned from LRU eviction.** The
   eviction loop walks past entries whose Future has not settled and
   only removes settled entries. Under a burst of >`maxEntries`
   unique keys the cache temporarily exceeds its bound; pending
   entries drain naturally as their Futures resolve. Without this
   pin, a retry of an evicted-but-still-running key would be a
   cache miss and start a second compute, breaking the
   concurrent-collapse guarantee in one process even before the
   restart-or-multi-instance failure modes below kick in.

### What we accept by deferring

- A proxy restart inside a client's retry window means the second
  retry rebuilds an empty cache, runs the toggle a second time, and
  emits a duplicate audit row. The flag value itself is unaffected:
  `UPDATE feature_flags SET enabled=…` is naturally idempotent at
  the row level. The risk surface is **audit drift, not state
  corruption**.
- The toggle route is single-Cloud-Run-instance today, so cross-
  instance dedup is not load-bearing; if the proxy ever scales out
  before the durable backstop lands, two parallel POSTs to different
  instances would each toggle once + emit one audit row each (same
  audit-drift class as restart, no flag corruption).

### When to promote to Postgres-durable

Two natural triggers:

1. **`admin_idempotency_cache` next gets touched** for any reason —
   add the `request_type` / `payload_hash` / `status` /
   `result_payload` / `completed_at` columns in the same migration,
   then swap `FeatureFlagToggleIdempotencyCache` for an
   `OperatorScopedRepository.withSystem`-backed reader/writer. Drop
   "Required Behavior" §1's `proxy_requests` reference in favor of
   `admin_idempotency_cache`.
2. **The proxy posture moves off single-instance** (Phase 12
   multi-region or a horizontal-scaling change). Multi-instance
   makes audit drift quantitatively worse, and the durable backstop
   becomes load-bearing rather than belt-and-braces.

Until either trigger fires, the in-memory layer is the contract's
operative implementation.
