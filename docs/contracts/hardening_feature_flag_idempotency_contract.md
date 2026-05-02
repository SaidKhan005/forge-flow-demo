# Hardening — Feature Flag Idempotency Contract

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
