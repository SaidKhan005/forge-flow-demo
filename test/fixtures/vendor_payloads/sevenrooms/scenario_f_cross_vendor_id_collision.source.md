# Source

- URL: https://academy.airship.co.uk/en/articles/12277047-how-to-get-api-credentials-from-sevenrooms (vendor entity id shape)
- Internal contract: `SevenRoomsReservationGateway.writeReservationFact` doc comment in `lib/integrations/reservation/sevenrooms_reservation_adapter.dart` lines 184-195: "the idempotency UNIQUE on `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)` short-circuited the upsert"
- Doctrine: `docs/contracts/vendor_adapter_slice_contract.md` (idempotency-key namespace prevents shadow-write across vendors)
- Retrieved: 2026-05-08
- API version: partner API `2_2` (pinned `v2_2_2026_05`)
- Endpoint: any (incremental poll, export, or webhook)
- Notes: SevenRooms reservation IDs are documented as opaque strings (`uuid-style` per the adapter source comment). A short alphanumeric value like `RES-12345` is intentionally chosen because it's a plausible shape for a parallel OpenTable reservation token (or any other reservation vendor's reference number), so naive de-duplication on `vendor_entity_id` alone would shadow-write across vendors. The four-tuple UNIQUE prevents this. The fixture is structured as collision_inputs (two records intended to land in disjoint namespaces) plus the actual payload SevenRooms would emit; the Phase 2 sink harness drives both inputs and asserts both succeed. Replay of the SevenRooms payload (same four-tuple) must short-circuit at the gateway without overwriting the canonical fact row.
