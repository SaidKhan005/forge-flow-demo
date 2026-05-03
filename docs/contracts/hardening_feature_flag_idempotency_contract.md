# Hardening - Feature Flag Idempotency Contract

Status: Closed / active authority
Updated: 2026-05-03
Owner: HARD-D + HARD-H idempotency sprint

HARD-D first shipped the in-process collapse behavior for
`POST /v1/admin/feature-flags/toggle` (`5b51fd0`, PR #45). HARD-H then
shipped the Postgres-durable cross-tenant admin backstop in
`public.admin_request_idempotency`
(`202605021000_phase_hardh_admin_idempotency.sql`).

This document is the current contract for feature-flag toggle idempotency and
the shared admin-route idempotency pattern.

## Current Durable Store

Use `public.admin_request_idempotency` for F&F admin routes whose actor is
global/cross-tenant and therefore cannot write a tenant-scoped
`proxy_requests` row.

The table stores:

- `idempotency_key` primary key
- `request_type`
- `actor_user_id`
- `request_body_hash`
- `response_status`
- `response_payload`
- `created_at`
- `completed_at`

`service_role` can select/insert/update. `forge_admin` can select for
operational visibility. Mutations must flow through the proxy.

## Required Behavior

For `POST /v1/admin/feature-flags/toggle`:

1. Require a non-empty `Idempotency-Key` header, max 200 chars.
2. Canonicalize the request body and compute a SHA-256 `request_body_hash`.
3. Look up `admin_request_idempotency` by key.
4. If the key exists with a different `request_type` or body hash, return
   HTTP 409 `idempotency_key_conflict` and do not mutate.
5. If the key exists and has a completed response, replay
   `response_status` + `response_payload` without a second mutation or audit
   row.
6. If the key exists but has no completed response, return HTTP 409
   `idempotency_request_in_flight`.
7. If no row exists, reserve the key, run the toggle, emit the audit event in
   the same mutation path, then write `response_status`,
   `response_payload`, and `completed_at`.

## In-Process Collapse

The in-process cache remains useful for same-instance concurrent retries. It
is keyed by `(request_type, idempotency_key)`, carries the request body hash,
and pins in-flight futures so a retry cannot start a second compute before the
first one settles.

The durable table is the source of truth across restarts and future horizontal
scale.

## Shared Admin Pattern

Operator/location, pricing tier, and integration admin routes share the same
Postgres-durable pattern through `_runAdminIdempotent` and the
`AdminRequestIdempotencyStore` binding.

Do not use `proxy_requests` for cross-tenant admin operations; it is
tenant-scoped and requires `operator_id` + `location_id`.

Do not extend `admin_idempotency_cache` for this purpose; that table belongs
to corpus/admin ledger flows.

## Evidence

- Durable table migration:
  `db/migrations/202605021000_phase_hardh_admin_idempotency.sql`
- Store implementation:
  `tool/advisor_proxy/proxy_bootstrap.dart`
  (`PostgresAdminRequestIdempotencyStore`)
- Shared helper:
  `tool/advisor_proxy/advisor_proxy.dart` (`_runAdminIdempotent`)
- Live binding / retry tests:
  `test/feature_flags_admin_live_binding_test.dart`
- Admin gateway retry tests:
  `test/admin/operator_location_admin_gateway_test.dart`
  `test/admin/pricing_tier_admin_gateway_test.dart`
  `test/admin/integration_admin_gateway_test.dart`
