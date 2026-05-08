# Source

- URL: https://developers.pushoperations.com/
- Retrieved: 2026-05-08
- API version: v1 (REST API at /api/v1/...)
- Endpoint: GET /api/v1/shifts (with deliberately-colliding 7shifts payload for the cross-vendor collision pressure)
- Notes: The Push Operations canonical UNIQUE is documented in the
  adapter file:
  `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
  (see `PushOperationsCanonicalSink.upsertShift` doc comment at
  `lib/integrations/labor/push_operations_labor_adapter.dart`
  lines 113-120). The proxy's idempotency-key namespace is also
  vendor-scoped per `proxy_requests` UNIQUE (see
  `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
  + `proxy_requests.idempotency_key` UNIQUE constraint at
  `db/migrations/202604250005_advisor_cloud_foundation.sql:198`).

  This fixture deliberately reuses the `id = 800101` value across
  Push Operations and 7shifts to force the test:
  1. Proxy idempotency-key namespace SHOULD prevent the second write
     from being rejected as a duplicate (the keys differ because
     `vendor_id` is part of the key composition).
  2. Canonical sink should persist BOTH rows: one
     `(push_operations, ..., '800101', ...)` and one
     `(seven_shifts, ..., '800101', ...)`.
  3. NO shadow-write where the Push row is overwritten by the
     7shifts row or vice versa.

  The 7shifts payload here is a minimal vendor-shape sketch for the
  cross-vendor collision test only; the canonical 7shifts payload
  set lives in `test/fixtures/vendor_payloads/seven_shifts/`.
